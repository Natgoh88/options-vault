// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PricingEngine} from "../src/PricingEngine.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {OptionsVault} from "../src/OptionsVault.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {IPricingEngine} from "../src/interfaces/IPricingEngine.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {ISettlementResolver} from "../src/interfaces/ISettlementResolver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20, MockResolver} from "./mocks/Mocks.sol";

abstract contract VaultBase is Test {
    MockERC20 weth;
    MockERC20 usdc;
    MockResolver resolver;
    PricingEngine engine;
    OptionToken token;
    OptionsVault vault;

    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address buyer = makeAddr("buyer");

    struct Deployment {
        MockERC20 weth;
        MockERC20 usdc;
        MockResolver resolver;
        OptionToken token;
        OptionsVault vault;
        address keeper;
    }

    function _deployment() internal view returns (Deployment memory) {
        return Deployment(weth, usdc, resolver, token, vault, keeper);
    }

    uint256 constant SPOT = 2000e18;
    uint256 constant EPOCH = 7 days;
    uint256 constant WRITING = 1 hours;
    uint256 constant IDLE = 1 hours;
    uint256 constant MAX_DEV_BPS = 100; // 1%
    uint256 constant MARKUP_BPS = 200; // 2%
    uint256 constant MIN_FILL_BPS = 1000; // 10% must sell or the epoch is cancelled

    function _deploy() internal {
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        resolver = new MockResolver();
        resolver.setPrice(SPOT);
        engine = new PricingEngine(keeper, 1 hours, 24, 0.05e18, 0.3e18, 5e18);
        token = new OptionToken();
        vault = new OptionsVault(
            IERC20(address(weth)),
            IERC20(address(usdc)),
            IPricingEngine(address(engine)),
            ISettlementResolver(address(resolver)),
            IOptionToken(address(token)),
            keeper,
            OptionsVault.Params({
                epochDuration: EPOCH,
                writingWindow: WRITING,
                idleWindow: IDLE,
                targetDelta: 0.3e18,
                maxSpotDeviationBps: MAX_DEV_BPS,
                premiumMarkupBps: MARKUP_BPS,
                minFillBps: MIN_FILL_BPS
            })
        );
        token.setVault(address(vault));

        // seed realized-vol history: alternating +/-1.5% hourly moves
        vm.startPrank(keeper);
        uint256 px = SPOT;
        engine.recordSnapshot(px);
        for (uint256 i; i < 24; ++i) {
            vm.warp(block.timestamp + 1 hours);
            px = i % 2 == 0 ? px * 1015 / 1000 : px * 1000 / 1015;
            engine.recordSnapshot(px);
        }
        vm.stopPrank();
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    function _start() internal {
        vm.prank(keeper);
        vault.startEpoch();
    }

    function _buy(address who, uint256 amount) internal returns (uint256 cost) {
        IOptionsVault.Epoch memory e = vault.epochData(vault.currentEpoch());
        uint256 est = amount * e.premiumPerOption / 1e18 + 1;
        usdc.mint(who, est);
        vm.startPrank(who);
        usdc.approve(address(vault), est);
        cost = vault.buyOptions(amount);
        vm.stopPrank();
    }

    /// Run the remainder of an epoch: activate, warp to expiry, settle at `price`.
    function _finish(uint256 price) internal {
        IOptionsVault.Epoch memory e = vault.epochData(vault.currentEpoch());
        if (vault.state() == IOptionsVault.State.Writing) {
            if (block.timestamp <= e.writingEnd) vm.warp(e.writingEnd + 1);
            vault.activate();
        }
        vm.warp(e.expiry);
        resolver.setPrice(price);
        vault.beginSettlement();
        vault.settle();
    }
}

contract OptionsVaultTest is VaultBase {
    function setUp() public {
        _deploy();
    }

    // ---------------- deposits / state gating ----------------

    function test_depositWithdrawInIdle() public {
        uint256 shares = _deposit(alice, 10e18);
        assertGt(shares, 0);
        assertEq(vault.totalAssets(), 10e18);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(weth.balanceOf(alice), 10e18);
    }

    function test_depositAndWithdrawBlockedOutsideIdle() public {
        _deposit(alice, 10e18);
        _start();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        weth.mint(bob, 1e18);
        vm.startPrank(bob);
        weth.approve(address(vault), 1e18);
        vm.expectRevert();
        vault.deposit(1e18, bob);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1e18, alice, alice);
    }

    // ---------------- access control / state machine ----------------

    function test_startEpochOnlyKeeper() public {
        _deposit(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(IOptionsVault.NotKeeper.selector);
        vault.startEpoch();
    }

    function test_startEpochNeedsAssets() public {
        vm.prank(keeper);
        vm.expectRevert(IOptionsVault.NothingToLock.selector);
        vault.startEpoch();
    }

    function test_wrongStateReverts() public {
        _deposit(alice, 10e18);
        vm.expectRevert(abi.encodeWithSelector(IOptionsVault.WrongState.selector, 0));
        vault.activate();
        vm.expectRevert(abi.encodeWithSelector(IOptionsVault.WrongState.selector, 0));
        vault.beginSettlement();
        vm.expectRevert(abi.encodeWithSelector(IOptionsVault.WrongState.selector, 0));
        vault.settle();
        _start();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IOptionsVault.WrongState.selector, 1));
        vault.startEpoch();
        vm.expectRevert(abi.encodeWithSelector(IOptionsVault.WrongState.selector, 1));
        vault.beginSettlement();
    }

    function test_startEpochSetsStrikeAbovePremiumPositive() public {
        _deposit(alice, 10e18);
        _start();
        IOptionsVault.Epoch memory e = vault.epochData(1);
        assertGt(e.strike, SPOT);
        assertGt(e.premiumPerOption, 0);
        assertEq(e.collateralLocked, 10e18);
        assertEq(e.expiry, block.timestamp + EPOCH);
        // delta at chosen strike ~ 0.3
        uint256 vol = engine.realizedVolatility();
        assertApproxEqAbs(engine.callDelta(SPOT, e.strike, vol, EPOCH), 0.3e18, 1e12);
    }

    function test_buyExceedsCollateralReverts() public {
        _deposit(alice, 10e18);
        _start();
        usdc.mint(buyer, 1e12);
        vm.startPrank(buyer);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(IOptionsVault.ExceedsCollateral.selector);
        vault.buyOptions(10e18 + 1);
        vm.expectRevert(IOptionsVault.ZeroAmount.selector);
        vault.buyOptions(0);
        vm.stopPrank();
    }

    function test_buyAfterWritingWindowReverts() public {
        _deposit(alice, 10e18);
        _start();
        vm.warp(block.timestamp + WRITING + 1);
        usdc.mint(buyer, 1e12);
        vm.startPrank(buyer);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(IOptionsVault.WritingClosed.selector);
        vault.buyOptions(1e18);
        vm.stopPrank();
    }

    function test_activateTooEarlyThenAfterSellOutOrWindow() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 5e18);
        vm.expectRevert(IOptionsVault.WritingStillOpen.selector);
        vault.activate();
        vm.warp(block.timestamp + WRITING + 1);
        vault.activate();
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Active));
    }

    function test_activateImmediatelyWhenSoldOut() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 10e18);
        vault.activate();
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Active));
    }

    function test_beginSettlementTooEarlyReverts() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 10e18);
        vault.activate();
        vm.expectRevert(IOptionsVault.TooEarly.selector);
        vault.beginSettlement();
    }

    function test_redeemUnsettledReverts() public {
        _deposit(alice, 10e18);
        _start();
        vm.prank(buyer);
        vm.expectRevert(IOptionsVault.NotSettled.selector);
        vault.redeemOptions(1, 1e18);
    }

    function test_optionTokenOnlyVault() public {
        vm.expectRevert(IOptionToken.NotVault.selector);
        token.mint(address(this), 1, 1, 1);
        vm.expectRevert(IOptionToken.NotVault.selector);
        token.burn(address(this), 1, 1, 1);
        vm.expectRevert(OptionToken.VaultAlreadySet.selector);
        token.setVault(address(1));
    }

    // ---------------- economics ----------------

    function test_otmEpoch_depositorKeepsCollateralAndEarnsPremium() public {
        uint256 shares = _deposit(alice, 10e18);
        _start();
        uint256 cost = _buy(buyer, 10e18);
        assertGt(cost, 0);
        _finish(SPOT); // below strike => OTM

        IOptionsVault.Epoch memory e = vault.epochData(1);
        assertEq(e.payoutPerOption, 0);
        assertEq(vault.reservedPayout(), 0);
        assertTrue(e.settled);

        // premium fully claimable by sole depositor (dust < 1 USDC unit per share rounding)
        assertApproxEqAbs(vault.pendingPremium(alice), cost, 1);
        vm.prank(alice);
        vault.claimPremium();
        assertApproxEqAbs(usdc.balanceOf(alice), cost, 1);

        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(weth.balanceOf(alice), 10e18);

        // buyer's options are worthless; redeem burns for 0
        vm.prank(buyer);
        uint256 payout = vault.redeemOptions(1, 10e18);
        assertEq(payout, 0);
    }

    function test_itmEpoch_holderPaidInWethDepositorNet() public {
        uint256 shares = _deposit(alice, 10e18);
        _start();
        _buy(buyer, 10e18);
        IOptionsVault.Epoch memory e0 = vault.epochData(1);
        uint256 price = e0.strike * 12 / 10; // 20% above strike
        _finish(price);

        IOptionsVault.Epoch memory e = vault.epochData(1);
        uint256 expectedPpo = (price - e.strike) * 1e18 / price;
        assertEq(e.payoutPerOption, expectedPpo);
        uint256 total = 10e18 * expectedPpo / 1e18;
        assertEq(vault.reservedPayout(), total);
        // reserved WETH is excluded from depositor assets
        assertEq(vault.totalAssets(), 10e18 - total);

        vm.prank(buyer);
        uint256 payout = vault.redeemOptions(1, 10e18);
        assertEq(payout, total);
        assertEq(weth.balanceOf(buyer), total);
        assertEq(vault.reservedPayout(), 0);

        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertApproxEqAbs(out, 10e18 - total, 1e4); // virtual-share rounding dust
    }

    function test_partialFillOnlyPaysSoldOptions() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 4e18);
        uint256 price = vault.epochData(1).strike * 2;
        _finish(price);
        uint256 ppo = vault.epochData(1).payoutPerOption;
        assertEq(vault.reservedPayout(), 4e18 * ppo / 1e18);
    }

    function test_lateDepositorGetsNoPastPremium() public {
        _deposit(alice, 10e18);
        _start();
        uint256 cost = _buy(buyer, 10e18);
        _finish(SPOT);

        uint256 bobShares = _deposit(bob, 10e18);
        assertEq(vault.pendingPremium(bob), 0);
        assertApproxEqAbs(vault.pendingPremium(alice), cost, 1);

        // epoch 2: premium now splits ~50/50
        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(keeper);
        engine.recordSnapshot(SPOT);
        vm.stopPrank();
        _start();
        uint256 cost2 = _buy(buyer, 20e18);
        vault.activate();
        assertApproxEqRel(vault.pendingPremium(bob), cost2 / 2, 1e12);
        assertGt(bobShares, 0);
    }

    function test_premiumFollowsShareTransfer() public {
        uint256 shares = _deposit(alice, 10e18);
        _start();
        uint256 cost = _buy(buyer, 10e18);
        vault.activate(); // sold out
        // premium accrued to alice before transfer stays with alice
        vm.prank(alice);
        vault.transfer(bob, shares / 2);
        assertApproxEqAbs(vault.pendingPremium(alice), cost, 1);
        assertEq(vault.pendingPremium(bob), 0);
    }

    function test_optionsTransferableAndRedeemableByNewHolder() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 10e18);
        uint256 strike = vault.epochData(1).strike;
        uint256 expiry = vault.epochData(1).expiry;
        uint256 id = token.tokenId(strike, expiry);
        vm.prank(buyer);
        token.safeTransferFrom(buyer, bob, id, 10e18, "");
        _finish(strike * 2);
        vm.prank(bob);
        uint256 payout = vault.redeemOptions(1, 10e18);
        assertGt(payout, 0);
    }

    function test_donationDoesNotBreakShareAccounting() public {
        _deposit(alice, 10e18);
        weth.mint(address(vault), 5e18); // donation
        assertEq(vault.totalAssets(), 15e18);
        uint256 bobShares = _deposit(bob, 15e18);
        // bob's shares are worth ~what he put in (not diluted to zero, not stolen)
        assertApproxEqAbs(vault.convertToAssets(bobShares), 15e18, 1e6);
    }
}
