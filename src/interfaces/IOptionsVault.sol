// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC-4626 covered-call vault over WETH with weekly epochs.
/// @dev Inherit IERC4626 in the implementation. Deposits/withdrawals are only possible in Idle, and
///      Idle lasts at least `idleWindow` after every epoch so depositors can always exit.
///      Premium is paid in USDC (6 decimals) and streamed to shareholders via an accumulator;
///      option payouts are cash-settled in WETH and claimed by holders via `redeemOptions`.
interface IOptionsVault {
    enum State {
        Idle,
        Writing,
        Active,
        Settling
    }

    struct Epoch {
        uint256 strike; // USD per WETH, 1e18
        uint256 expiry; // unix seconds
        uint256 writingEnd; // last timestamp options can be bought
        uint256 spotAtStart; // USD per WETH, 1e18; quotes are only valid near this spot
        uint256 collateralLocked; // WETH, max options that can be sold
        uint256 premiumPerOption; // USDC (6 dec) per 1e18 options
        uint256 optionsSold; // WETH-denominated notional, 1e18
        uint256 premiumCollected; // USDC (6 dec)
        uint256 settlementPrice; // USD per WETH, 1e18
        uint256 payoutPerOption; // WETH (1e18) per 1e18 options
        bool settled;
    }

    error WrongState(State current);
    error NotKeeper();
    error WritingClosed();
    error WritingStillOpen();
    error ExceedsCollateral();
    error NothingToLock();
    error TooEarly();
    error NotSettled();
    error ZeroAmount();
    error ZeroAddress();
    error ZeroPremium();
    error SpotMoved(uint256 spotAtStart, uint256 spotNow);
    error InvalidParams();

    event EpochStarted(
        uint256 indexed epoch, uint256 strike, uint256 expiry, uint256 collateral, uint256 premium
    );
    event OptionsPurchased(
        uint256 indexed epoch, address indexed buyer, uint256 amount, uint256 premium
    );
    event EpochActivated(uint256 indexed epoch, uint256 optionsSold, uint256 premiumCollected);
    event EpochSkipped(uint256 indexed epoch);
    event SettlementStarted(uint256 indexed epoch, uint256 settlementPrice);
    event EpochSettled(uint256 indexed epoch, uint256 payoutPerOption, uint256 totalPayout);
    event OptionsRedeemed(
        uint256 indexed epoch, address indexed holder, uint256 amount, uint256 payout
    );
    event PremiumClaimed(address indexed account, uint256 amount);

    function state() external view returns (State);
    function currentEpoch() external view returns (uint256);
    function epochData(uint256 epoch) external view returns (Epoch memory);

    /// @notice Timestamp the vault last entered Idle (deposit/withdraw window opens).
    function idleSince() external view returns (uint256);
    /// @notice Minimum time spent in Idle before a new epoch may start.
    function idleWindow() external view returns (uint256);

    /// @notice Idle -> Writing: pick strike via PricingEngine, lock collateral, fix premium.
    function startEpoch() external;

    /// @notice Writing: buyer pays USDC premium and receives OptionToken. Reverts if spot has
    ///         moved more than the allowed deviation from the epoch-start spot (stale quote).
    function buyOptions(uint256 amount) external returns (uint256 premium);

    /// @notice Writing -> Active once sold out or the writing window has closed. If nothing was
    ///         sold the epoch is skipped and the vault returns straight to Idle (no lock-up).
    function activate() external;

    /// @notice Active -> Settling: read the recorded settlement price after expiry.
    function beginSettlement() external;

    /// @notice Settling -> Idle: fix payout per option and reserve the WETH for holders.
    function settle() external;

    /// @notice Burn `amount` options of a settled epoch and receive the WETH payout.
    function redeemOptions(uint256 epoch, uint256 amount) external returns (uint256 payout);

    /// @notice Claim accrued USDC premium.
    function claimPremium() external returns (uint256 amount);

    function pendingPremium(address account) external view returns (uint256);

    /// @notice WETH reserved for option holders who have not redeemed yet.
    function reservedPayout() external view returns (uint256);
}
