// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOptionsVault} from "./interfaces/IOptionsVault.sol";
import {IPricingEngine} from "./interfaces/IPricingEngine.sol";
import {IOptionToken} from "./interfaces/IOptionToken.sol";
import {ISettlementResolver} from "./interfaces/ISettlementResolver.sol";

/// @title OptionsVault
/// @notice ERC-4626 WETH vault that writes weekly covered calls priced on-chain.
/// @dev Epoch state machine: Idle -> Writing -> Active -> Settling -> Idle.
///      Deposits/withdrawals are only enabled in Idle so collateral cannot move mid-epoch.
///      Rounding always favours the vault: premium rounds up, payouts round down.
contract OptionsVault is ERC4626, Ownable, ReentrancyGuard, IOptionsVault {
    using SafeERC20 for IERC20;

    uint256 internal constant PREMIUM_SCALE = 1e30;
    uint256 internal constant USDC_SCALE = 1e12; // 1e18 USD -> 6-decimals USDC

    IPricingEngine public immutable engine;
    ISettlementResolver public immutable resolver;
    IOptionToken public immutable optionToken;
    IERC20 public immutable usdc;
    uint256 public immutable epochDuration;
    uint256 public immutable writingWindow;
    uint256 public immutable targetDelta; // 1e18, e.g. 0.3e18

    address public keeper;

    State public state;
    uint256 public currentEpoch;
    uint256 public reservedPayout;
    mapping(uint256 => Epoch) internal _epochs;

    // USDC premium accumulator (MasterChef-style, per share, scaled by PREMIUM_SCALE)
    uint256 public accPremiumPerShare;
    mapping(address => uint256) internal _premiumDebt;
    mapping(address => uint256) internal _premiumOwed;

    event KeeperSet(address indexed keeper);

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier inState(State s) {
        if (state != s) revert WrongState(state);
        _;
    }

    constructor(
        IERC20 weth,
        IERC20 usdc_,
        IPricingEngine engine_,
        ISettlementResolver resolver_,
        IOptionToken optionToken_,
        address keeper_,
        uint256 epochDuration_,
        uint256 writingWindow_,
        uint256 targetDelta_
    ) ERC20("Options Vault WETH", "ovWETH") ERC4626(weth) Ownable(msg.sender) {
        require(IERC20Metadata(address(usdc_)).decimals() == 6, "USDC decimals");
        require(targetDelta_ > 0 && targetDelta_ < 1e18, "delta");
        require(epochDuration_ > 0 && writingWindow_ < epochDuration_, "durations");
        usdc = usdc_;
        engine = engine_;
        resolver = resolver_;
        optionToken = optionToken_;
        keeper = keeper_;
        epochDuration = epochDuration_;
        writingWindow = writingWindow_;
        targetDelta = targetDelta_;
        emit KeeperSet(keeper_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    // ------------------------------------------------------------------
    // ERC-4626 overrides
    // ------------------------------------------------------------------

    /// @dev WETH held minus WETH already owed to option holders of settled epochs.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - reservedPayout;
    }

    function maxDeposit(address account) public view override returns (uint256) {
        return state == State.Idle ? super.maxDeposit(account) : 0;
    }

    function maxMint(address account) public view override returns (uint256) {
        return state == State.Idle ? super.maxMint(account) : 0;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return state == State.Idle ? super.maxWithdraw(owner_) : 0;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return state == State.Idle ? super.maxRedeem(owner_) : 0;
    }

    /// @dev Virtual-share offset to blunt first-depositor donation/inflation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    // ------------------------------------------------------------------
    // Epoch state machine
    // ------------------------------------------------------------------

    /// @inheritdoc IOptionsVault
    function startEpoch() external onlyKeeper inState(State.Idle) {
        uint256 locked = totalAssets();
        if (locked == 0 || totalSupply() == 0) revert NothingToLock();

        uint256 spot = resolver.spot();
        uint256 vol = engine.realizedVolatility();
        uint256 strike = engine.strikeForDelta(spot, vol, epochDuration, targetDelta);
        uint256 premiumUsd = engine.callPrice(spot, strike, vol, epochDuration);
        uint256 premiumUsdc = Math.ceilDiv(premiumUsd, USDC_SCALE); // round up: favours vault

        uint256 id = ++currentEpoch;
        Epoch storage e = _epochs[id];
        e.strike = strike;
        e.expiry = block.timestamp + epochDuration;
        e.writingEnd = block.timestamp + writingWindow;
        e.collateralLocked = locked;
        e.premiumPerOption = premiumUsdc;
        state = State.Writing;

        emit EpochStarted(id, strike, e.expiry, locked, premiumUsdc);
    }

    /// @inheritdoc IOptionsVault
    function buyOptions(uint256 amount)
        external
        nonReentrant
        inState(State.Writing)
        returns (uint256 premium)
    {
        if (amount == 0) revert ZeroAmount();
        Epoch storage e = _epochs[currentEpoch];
        if (block.timestamp > e.writingEnd) revert WritingClosed();
        if (e.optionsSold + amount > e.collateralLocked) revert ExceedsCollateral();

        premium = Math.mulDiv(amount, e.premiumPerOption, 1e18, Math.Rounding.Ceil);
        e.optionsSold += amount;
        e.premiumCollected += premium;

        usdc.safeTransferFrom(msg.sender, address(this), premium);
        optionToken.mint(msg.sender, e.strike, e.expiry, amount);
        emit OptionsPurchased(currentEpoch, msg.sender, amount, premium);
    }

    /// @inheritdoc IOptionsVault
    function activate() external inState(State.Writing) {
        Epoch storage e = _epochs[currentEpoch];
        if (e.optionsSold < e.collateralLocked && block.timestamp <= e.writingEnd) {
            revert WritingStillOpen();
        }
        state = State.Active;
        if (e.premiumCollected > 0) {
            accPremiumPerShare += Math.mulDiv(e.premiumCollected, PREMIUM_SCALE, totalSupply());
        }
        emit EpochActivated(currentEpoch, e.optionsSold, e.premiumCollected);
    }

    /// @inheritdoc IOptionsVault
    function beginSettlement() external inState(State.Active) {
        Epoch storage e = _epochs[currentEpoch];
        if (block.timestamp < e.expiry) revert TooEarly();
        uint256 price = resolver.snapshotSettlementPrice(currentEpoch);
        e.settlementPrice = price;
        state = State.Settling;
        emit SettlementStarted(currentEpoch, price);
    }

    /// @inheritdoc IOptionsVault
    function settle() external inState(State.Settling) {
        Epoch storage e = _epochs[currentEpoch];
        uint256 price = e.settlementPrice;
        uint256 ppo = price > e.strike ? Math.mulDiv(price - e.strike, 1e18, price) : 0; // rounds down
        uint256 total = Math.mulDiv(e.optionsSold, ppo, 1e18); // rounds down
        e.payoutPerOption = ppo;
        e.settled = true;
        reservedPayout += total;
        state = State.Idle;
        emit EpochSettled(currentEpoch, ppo, total);
    }

    /// @inheritdoc IOptionsVault
    function redeem(uint256 epoch, uint256 amount)
        external
        override(IOptionsVault)
        nonReentrant
        returns (uint256 payout)
    {
        Epoch storage e = _epochs[epoch];
        if (!e.settled) revert NotSettled();
        if (amount == 0) revert ZeroAmount();
        payout = Math.mulDiv(amount, e.payoutPerOption, 1e18); // rounds down
        optionToken.burn(msg.sender, e.strike, e.expiry, amount);
        reservedPayout -= payout;
        IERC20(asset()).safeTransfer(msg.sender, payout);
        emit OptionsRedeemed(epoch, msg.sender, amount, payout);
    }

    // ------------------------------------------------------------------
    // USDC premium accounting
    // ------------------------------------------------------------------

    function pendingPremium(address account) public view returns (uint256) {
        uint256 acc = accPremiumPerShare;
        return _premiumOwed[account]
            + Math.mulDiv(balanceOf(account), acc - _premiumDebt[account], PREMIUM_SCALE);
    }

    function claimPremium() external nonReentrant returns (uint256 amount) {
        _harvest(msg.sender);
        amount = _premiumOwed[msg.sender];
        _premiumOwed[msg.sender] = 0;
        if (amount > 0) usdc.safeTransfer(msg.sender, amount);
        emit PremiumClaimed(msg.sender, amount);
    }

    function _harvest(address account) internal {
        _premiumOwed[account] = pendingPremium(account);
        _premiumDebt[account] = accPremiumPerShare;
    }

    /// @dev Settle premium for both parties before any balance change (mint/burn/transfer).
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) _harvest(from);
        if (to != address(0)) _harvest(to);
        super._update(from, to, value);
    }

    function epochData(uint256 epoch) external view returns (Epoch memory) {
        return _epochs[epoch];
    }
}
