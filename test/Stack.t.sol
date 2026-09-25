// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PricingEngine} from "../src/PricingEngine.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {OptionsVault} from "../src/OptionsVault.sol";
import {SettlementResolver} from "../src/SettlementResolver.sol";
import {VaultKeeper} from "../src/VaultKeeper.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {IPricingEngine} from "../src/interfaces/IPricingEngine.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {ISettlementResolver} from "../src/interfaces/ISettlementResolver.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockERC20, MockAggregator} from "./mocks/Mocks.sol";

/// Real stack: PricingEngine + OptionsVault + OptionToken + SettlementResolver + VaultKeeper over
/// a mock Chainlink feed with full round history.
abstract contract StackBase is Test {
    MockERC20 weth;
    MockERC20 usdc;
    MockAggregator feed;
    MockAggregator sequencer;
    VaultKeeper kc;
    PricingEngine engine;
    SettlementResolver resolver;
    OptionToken token;
    OptionsVault vault;

    address forwarder = makeAddr("forwarder");
    address alice = makeAddr("alice");
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");

    uint256 constant HEARTBEAT = 1 days;
    uint256 constant BUFFER = 1 hours;
    uint256 constant GRACE = 1 hours;
    uint256 constant EPOCH = 7 days;
    uint256 constant WRITING = 1 hours;
    uint256 constant IDLE = 2 hours;
    uint256 constant FALLBACK = 2 days;
    uint256 constant MIN_FILL_BPS = 1000;

    int256 px = 2000e8; // feed decimals = 8
    bool up;

    function _deployStack() internal {
        vm.warp(1_700_000_000);
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        feed = new MockAggregator(8);
        sequencer = new MockAggregator(0);
        sequencer.push(0); // up since now

        kc = new VaultKeeper(6);
        engine = new PricingEngine(address(kc), 1 hours, 24, 0.05e18, 0.3e18, 5e18);
        resolver = new SettlementResolver(
            AggregatorV3Interface(address(feed)),
            AggregatorV3Interface(address(sequencer)),
            HEARTBEAT,
            BUFFER,
            GRACE,
            FALLBACK
        );
        token = new OptionToken();
        vault = new OptionsVault(
            IERC20(address(weth)),
            IERC20(address(usdc)),
            IPricingEngine(address(engine)),
            ISettlementResolver(address(resolver)),
            IOptionToken(address(token)),
            address(kc),
            OptionsVault.Params({
                epochDuration: EPOCH,
                writingWindow: WRITING,
                idleWindow: IDLE,
                targetDelta: 0.3e18,
                maxSpotDeviationBps: 100,
                premiumMarkupBps: 200,
                minFillBps: MIN_FILL_BPS
            })
        );
        token.setVault(address(vault));
        resolver.setVault(IOptionsVault(address(vault)));
        kc.init(
            engine, IOptionsVault(address(vault)), resolver, AggregatorV3Interface(address(feed))
        );
        kc.setForwarder(forwarder);

        feed.push(px);
        vm.warp(block.timestamp + 2 hours); // past sequencer grace
    }

    function _pushFeed() internal {
        px = up ? px * 1012 / 1000 : px * 1000 / 1012;
        up = !up;
        feed.push(px);
    }

    function _upkeep() internal returns (uint256 n) {
        for (uint256 i; i < 10; ++i) {
            (bool need, bytes memory data) = kc.checkUpkeep("");
            if (!need) break;
            vm.prank(forwarder);
            kc.performUpkeep(data);
            ++n;
        }
    }

    /// One hour passes, the feed updates, Automation runs whatever is due.
    function _tick() internal {
        vm.warp(block.timestamp + 1 hours);
        _pushFeed();
        _upkeep();
    }

    function _deposit(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
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

    function _tickUntil(IOptionsVault.State s) internal {
        for (uint256 i; i < 400 && vault.state() != s; ++i) {
            _tick();
        }
        assertEq(uint8(vault.state()), uint8(s), "state not reached");
    }

    /// Deposit, let Automation start epoch 1, buy some options, let it activate.
    function _toActive() internal returns (IOptionsVault.Epoch memory e) {
        _deposit(alice, 10e18);
        _tickUntil(IOptionsVault.State.Writing);
        _buy(buyer, 10e18);
        _tickUntil(IOptionsVault.State.Active);
        e = vault.epochData(1);
    }
}

contract SettlementResolverTest is StackBase {
    function setUp() public {
        _deployStack();
    }

    // ---------------- live spot ----------------

    function test_spotScalesDecimals() public view {
        assertEq(resolver.spot(), 2000e18);
    }

    function test_spotRevertsWhenStale() public {
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        uint256 maxAge = HEARTBEAT + BUFFER;
        vm.warp(updatedAt + maxAge); // exactly at the limit is still fine
        resolver.spot();
        vm.warp(updatedAt + maxAge + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementResolver.StalePrice.selector, updatedAt, maxAge)
        );
        resolver.spot();
    }

    function test_spotRevertsOnNonPositiveAnswer() public {
        feed.push(0);
        vm.expectRevert(ISettlementResolver.InvalidPrice.selector);
        resolver.spot();
        feed.push(-5);
        vm.expectRevert(ISettlementResolver.InvalidPrice.selector);
        resolver.spot();
    }

    function test_spotRevertsWhenSequencerDownOrJustRestarted() public {
        sequencer.push(1); // down
        vm.expectRevert(ISettlementResolver.SequencerDown.selector);
        resolver.spot();
        vm.warp(block.timestamp + 10 minutes);
        feed.push(px);
        sequencer.push(0); // back up just now
        vm.expectRevert(ISettlementResolver.GracePeriodNotOver.selector);
        resolver.spot();
        vm.warp(block.timestamp + GRACE + 1);
        feed.push(px);
        resolver.spot();
    }

    function test_setVaultOnlyDeployerOnce() public {
        vm.prank(attacker);
        vm.expectRevert(ISettlementResolver.NotDeployer.selector);
        resolver.setVault(IOptionsVault(attacker));
        vm.expectRevert(ISettlementResolver.VaultAlreadySet.selector);
        resolver.setVault(IOptionsVault(attacker));
    }

    // ---------------- settlement price: which round is valid ----------------

    /// Creates rounds: rA at expiry-30m (price A), rB at expiry+10m (price B). Returns ids.
    function _rounds(IOptionsVault.Epoch memory e, int256 a, int256 b)
        internal
        returns (uint80 rA, uint80 rB)
    {
        vm.warp(e.expiry - 30 minutes);
        feed.push(a);
        rA = feed.latestId();
        vm.warp(e.expiry + 10 minutes);
        feed.push(b);
        rB = feed.latestId();
        vm.warp(e.expiry + 1 hours);
    }

    function test_settlementUsesLastRoundAtOrBeforeExpiry() public {
        IOptionsVault.Epoch memory e = _toActive();
        (uint80 rA,) = _rounds(e, 2600e8, 9000e8);
        uint256 price = resolver.submitExpiryRound(1, rA);
        assertEq(price, 2600e18);
        assertEq(resolver.snapshotSettlementPrice(1), 2600e18);
        assertEq(resolver.settlementRound(1), rA);
    }

    function test_roundAfterExpiryRejected() public {
        IOptionsVault.Epoch memory e = _toActive();
        (, uint80 rB) = _rounds(e, 2600e8, 9000e8);
        vm.expectRevert(ISettlementResolver.RoundAfterExpiry.selector);
        resolver.submitExpiryRound(1, rB);
    }

    function test_earlierRoundRejected() public {
        IOptionsVault.Epoch memory e = _toActive();
        vm.warp(e.expiry - 2 hours);
        feed.push(2100e8);
        uint80 earlier = feed.latestId();
        (uint80 rA,) = _rounds(e, 2600e8, 9000e8);
        assertEq(rA, earlier + 1);
        vm.expectRevert(ISettlementResolver.NotLastRoundBeforeExpiry.selector);
        resolver.submitExpiryRound(1, earlier);
    }

    function test_tooEarlyAndUnknownRoundAndDoubleSubmit() public {
        IOptionsVault.Epoch memory e = _toActive();
        uint80 last = feed.latestId();
        vm.expectRevert(ISettlementResolver.TooEarly.selector);
        resolver.submitExpiryRound(1, last);

        vm.warp(e.expiry);
        vm.expectRevert(ISettlementResolver.TooEarly.selector); // == expiry still too early
        resolver.submitExpiryRound(1, last);

        (uint80 rA,) = _rounds(e, 2600e8, 9000e8);
        vm.expectRevert(ISettlementResolver.InvalidRound.selector);
        resolver.submitExpiryRound(1, 9999);
        vm.expectRevert(ISettlementResolver.InvalidRound.selector);
        resolver.submitExpiryRound(99, rA); // epoch that never existed

        resolver.submitExpiryRound(1, rA);
        vm.expectRevert(ISettlementResolver.AlreadyRecorded.selector);
        resolver.submitExpiryRound(1, rA);
    }

    function test_staleFeedAtExpiryRefusesToSettle() public {
        IOptionsVault.Epoch memory e = _toActive();
        // feed goes silent for the whole epoch; latest round is days old at expiry
        vm.warp(e.expiry + 1 hours);
        uint80 last = feed.latestId();
        vm.expectRevert();
        resolver.submitExpiryRound(1, last);
    }

    function test_payoutPerOptionFromRecordedPrice() public {
        IOptionsVault.Epoch memory e = _toActive();
        (uint80 rA,) = _rounds(e, 4000e8, 4000e8);
        resolver.submitExpiryRound(1, rA);
        assertEq(resolver.payoutPerOption(1, 3000e18), (4000e18 - 3000e18) * 1e18 / 4000e18);
        assertEq(resolver.payoutPerOption(1, 5000e18), 0);
        vm.expectRevert(ISettlementResolver.PriceNotRecorded.selector);
        resolver.payoutPerOption(2, 1);
    }

    // ---------------- exploit attempts against the settlement snapshot ----------------

    /// Attacker manipulates the feed in the settlement transaction (post-expiry) hoping the vault
    /// reads a spot at trigger time. The recorded price is the round in effect at expiry, so the
    /// manipulated round changes nothing, and cannot be submitted.
    function test_exploit_triggerTimeManipulationDoesNotMoveSettlement() public {
        IOptionsVault.Epoch memory e = _toActive();
        (uint80 rA,) = _rounds(e, 1500e8, 1500e8); // honest price: OTM for holders
        vm.startPrank(attacker);
        feed.push(90_000e8); // manipulated round at trigger time
        uint80 rM = feed.latestId();
        vm.expectRevert(ISettlementResolver.RoundAfterExpiry.selector);
        resolver.submitExpiryRound(1, rM);
        resolver.submitExpiryRound(1, rA); // anyone can submit, but only the one valid round
        vm.stopPrank();

        vault.beginSettlement();
        vault.settle();
        assertEq(vault.epochData(1).settlementPrice, 1500e18);
        assertEq(vault.epochData(1).payoutPerOption, 0);
    }

    /// Attacker tries to pick a more favourable historical round (e.g. a spike inside the epoch).
    function test_exploit_cannotCherryPickHistoricalSpike() public {
        IOptionsVault.Epoch memory e = _toActive();
        // spike shortly before expiry (fresh, so only the last-round rule can reject it)
        vm.warp(e.expiry - 2 hours);
        feed.push(8000e8);
        uint80 spike = feed.latestId();
        (uint80 rA,) = _rounds(e, 1500e8, 1500e8);
        vm.prank(attacker);
        vm.expectRevert(ISettlementResolver.NotLastRoundBeforeExpiry.selector);
        resolver.submitExpiryRound(1, spike);
        resolver.submitExpiryRound(1, rA);
        assertEq(resolver.snapshotSettlementPrice(1), 1500e18);
    }

    /// Settlement cannot begin until a price is recorded; a griefer cannot force a bad one.
    function test_exploit_beginSettlementNeedsRecordedPrice() public {
        IOptionsVault.Epoch memory e = _toActive();
        _rounds(e, 1500e8, 1500e8);
        vm.expectRevert(ISettlementResolver.PriceNotRecorded.selector);
        vault.beginSettlement();
    }
}

contract VaultKeeperTest is StackBase {
    function setUp() public {
        _deployStack();
    }

    function test_performUpkeepOnlyForwarder() public {
        (, bytes memory data) = kc.checkUpkeep("");
        vm.prank(attacker);
        vm.expectRevert(VaultKeeper.NotForwarder.selector);
        kc.performUpkeep(data);
    }

    /// performData is ignored: forged data cannot select an action, only what is due runs.
    function test_forgedPerformDataIgnored() public {
        _deposit(alice, 10e18);
        vm.warp(block.timestamp + 1 hours);
        feed.push(px);
        uint256 before = engine.lastTimestamp();
        // only a snapshot is due; ask for an epoch start / settlement instead
        vm.prank(forwarder);
        kc.performUpkeep(abi.encode(VaultKeeper.Action.StartEpoch, bytes("")));
        assertEq(vault.currentEpoch(), 0, "forged StartEpoch must not start an epoch");
        assertGt(engine.lastTimestamp(), before, "the due snapshot ran instead");

        // nothing due at all: reverts, so Automation never pays for a no-op
        vm.prank(forwarder);
        vm.expectRevert(VaultKeeper.NotNeeded.selector);
        kc.performUpkeep(abi.encode(VaultKeeper.Action.Settle, bytes("")));
    }

    /// A-4: Automation simulates in one block and executes in a later one. An upkeep simulated as
    /// "snapshot" just before the writing window closes lands after it; it must still succeed and
    /// run what is due now (Activate) instead of reverting.
    function test_staleSimulationAcrossBoundaryStillPerforms() public {
        _deposit(alice, 10e18);
        _tickUntil(IOptionsVault.State.Writing);
        _buy(buyer, 5e18);
        IOptionsVault.Epoch memory e = vault.epochData(1);
        vm.warp(e.writingEnd); // not yet closed
        feed.push(px);
        vm.warp(engine.lastTimestamp() + engine.sampleInterval()); // make a snapshot due
        if (block.timestamp > e.writingEnd) vm.warp(e.writingEnd);
        (bool need, bytes memory simulated) = kc.checkUpkeep("");
        assertTrue(need);

        vm.warp(e.writingEnd + 1); // executed one block later: window has closed
        vm.prank(forwarder);
        kc.performUpkeep(simulated);
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Active));
    }

    function test_initAndForwarderOnlyOwner() public {
        vm.startPrank(attacker);
        vm.expectRevert(VaultKeeper.NotOwner.selector);
        kc.setForwarder(attacker);
        vm.expectRevert(VaultKeeper.NotOwner.selector);
        kc.init(
            engine, IOptionsVault(address(vault)), resolver, AggregatorV3Interface(address(feed))
        );
        vm.stopPrank();
        vm.expectRevert(VaultKeeper.AlreadyInitialised.selector);
        kc.init(
            engine, IOptionsVault(address(vault)), resolver, AggregatorV3Interface(address(feed))
        );
    }

    function test_snapshotsAccumulateAndEpochStartsAfterMinSamples() public {
        _deposit(alice, 10e18);
        for (uint256 i; i < 5; ++i) {
            _tick();
        }
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Idle));
        assertLt(engine.sampleCount(), 6);
        _tickUntil(IOptionsVault.State.Writing);
        assertGe(engine.sampleCount(), 6);
        assertEq(vault.currentEpoch(), 1);
    }

    /// Automation alone runs snapshot -> start -> activate -> record price -> settle -> next epoch,
    /// and an ITM holder is paid from the real oracle price at expiry.
    function test_fullLifecycleDrivenByAutomation() public {
        _deposit(alice, 10e18);
        _tickUntil(IOptionsVault.State.Writing);
        _buy(buyer, 10e18);
        _tickUntil(IOptionsVault.State.Active);
        IOptionsVault.Epoch memory e = vault.epochData(1);

        // price rallies 25% above strike for the rest of the epoch
        px = int256(e.strike * 125 / 100 / 1e10);
        for (uint256 i; i < 400 && vault.currentEpoch() == 1; ++i) {
            vm.warp(block.timestamp + 1 hours);
            feed.push(px);
            _upkeep();
        }
        assertEq(vault.currentEpoch(), 2, "epoch 2 should have started");

        IOptionsVault.Epoch memory done = vault.epochData(1);
        assertTrue(done.settled);
        assertEq(done.settlementPrice, uint256(px) * 1e10);
        assertGt(done.payoutPerOption, 0);
        assertEq(resolver.snapshotSettlementPrice(1), done.settlementPrice);

        vm.prank(buyer);
        uint256 payout = vault.redeemOptions(1, 10e18);
        assertEq(payout, 10e18 * done.payoutPerOption / 1e18);
        assertEq(weth.balanceOf(buyer), payout);
    }

    function test_settlementLivenessIfNobodyBuys() public {
        _deposit(alice, 10e18);
        // no options are ever bought; the system must still roll epochs
        for (uint256 i; i < 400 && vault.currentEpoch() < 3; ++i) {
            _tick();
        }
        assertGe(vault.currentEpoch(), 3);
    }
}
