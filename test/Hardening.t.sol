// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VaultBase} from "./OptionsVault.t.sol";
import {StackBase} from "./Stack.t.sol";
import {MockERC20, MockAggregator} from "./mocks/Mocks.sol";

/// Tests for fixes from the pre-Phase-4 audit (vault side).
contract VaultHardeningTest is VaultBase {
    function setUp() public {
        _deploy();
    }

    // ---- depositors always get an exit window ----

    function test_idleWindowBlocksImmediateRestartAndAllowsExit() public {
        uint256 shares = _deposit(alice, 10e18);
        _start();
        _buy(buyer, 10e18);
        _finish(SPOT);

        // Keeper cannot roll straight into the next epoch...
        vm.prank(keeper);
        vm.expectRevert(IOptionsVault.TooEarly.selector);
        vault.startEpoch();

        // ...so depositors can leave in the meantime
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);
        assertEq(out, 10e18);

        // and the epoch can start once the window has passed
        _deposit(bob, 5e18);
        vm.warp(vault.idleSince() + IDLE);
        vm.prank(keeper);
        vault.startEpoch();
        assertEq(vault.currentEpoch(), 2);
    }

    // ---- stale-quote protection ----

    function test_buyRevertsWhenSpotMovedBeyondBand() public {
        _deposit(alice, 10e18);
        _start();
        usdc.mint(buyer, 1e12);
        vm.startPrank(buyer);
        usdc.approve(address(vault), type(uint256).max);

        resolver.setPrice(SPOT * 1020 / 1000); // +2% > 1% band
        vm.expectRevert(
            abi.encodeWithSelector(IOptionsVault.SpotMoved.selector, SPOT, SPOT * 1020 / 1000)
        );
        vault.buyOptions(1e18);

        resolver.setPrice(SPOT * 1005 / 1000); // +0.5% inside band
        vault.buyOptions(1e18);

        resolver.setPrice(SPOT * 990 / 1000); // exactly -1% is allowed (boundary)
        vault.buyOptions(1e18);
        vm.stopPrank();
    }

    // ---- safety margin ----

    function test_premiumIncludesMarkup() public {
        _deposit(alice, 10e18);
        _start();
        IOptionsVault.Epoch memory e = vault.epochData(1);
        uint256 vol = engine.realizedVolatility();
        uint256 fair = engine.callPrice(SPOT, e.strike, vol, EPOCH);
        uint256 marked = Math.mulDiv(fair, 10_000 + MARKUP_BPS, 10_000, Math.Rounding.Ceil);
        assertEq(e.premiumPerOption, Math.ceilDiv(marked, 1e12));
        assertGt(e.premiumPerOption, Math.ceilDiv(fair, 1e12));
    }

    // ---- no lock-up for an epoch nobody buys ----

    function test_unsoldEpochIsSkippedAndCollateralFreedImmediately() public {
        uint256 shares = _deposit(alice, 10e18);
        _start();
        vm.warp(block.timestamp + WRITING + 1);
        vault.activate();

        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Idle));
        assertTrue(vault.epochData(1).settled);
        assertEq(vault.idleSince(), block.timestamp);

        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 10e18);
    }

    // ---- constructor / admin hygiene ----

    function test_constructorRejectsBadParams() public {
        OptionsVault.Params memory good = OptionsVault.Params({
            epochDuration: EPOCH,
            writingWindow: WRITING,
            idleWindow: IDLE,
            targetDelta: 0.3e18,
            maxSpotDeviationBps: 100,
            premiumMarkupBps: 200,
            minFillBps: MIN_FILL_BPS
        });
        IERC20 w = IERC20(address(weth));
        IERC20 u = IERC20(address(usdc));
        IPricingEngine e = IPricingEngine(address(engine));
        ISettlementResolver r = ISettlementResolver(address(resolver));
        IOptionToken t = IOptionToken(address(token));

        vm.expectRevert(IOptionsVault.ZeroAddress.selector);
        new OptionsVault(w, u, e, r, t, address(0), good);

        OptionsVault.Params memory bad = good;
        bad.targetDelta = 1e18;
        vm.expectRevert(IOptionsVault.InvalidParams.selector);
        new OptionsVault(w, u, e, r, t, keeper, bad);

        bad = good;
        bad.maxSpotDeviationBps = 0;
        vm.expectRevert(IOptionsVault.InvalidParams.selector);
        new OptionsVault(w, u, e, r, t, keeper, bad);

        bad = good;
        bad.premiumMarkupBps = 5_001;
        vm.expectRevert(IOptionsVault.InvalidParams.selector);
        new OptionsVault(w, u, e, r, t, keeper, bad);

        bad = good;
        bad.writingWindow = EPOCH;
        vm.expectRevert(IOptionsVault.InvalidParams.selector);
        new OptionsVault(w, u, e, r, t, keeper, bad);

        // USDC must have 6 decimals
        MockERC20 usdc18 = new MockERC20("X", "X", 18);
        vm.expectRevert(IOptionsVault.InvalidParams.selector);
        new OptionsVault(w, IERC20(address(usdc18)), e, r, t, keeper, good);
    }

    function test_ownershipIsTwoStepAndKeeperCannotBeZero() public {
        vm.expectRevert(IOptionsVault.ZeroAddress.selector);
        vault.setKeeper(address(0));

        vault.transferOwnership(bob);
        assertEq(vault.owner(), address(this)); // not yet
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);

        vm.expectRevert(); // old owner lost control
        vault.setKeeper(alice);
    }
}

/// Engine fixes: interval-aware vol, closed-form strike solver.
contract EngineHardeningTest is Test {
    address keeper = address(0xBEEF);

    function _engine() internal returns (PricingEngine) {
        return new PricingEngine(keeper, 1 hours, 48, 0.05e18, 0.3e18, 5e18);
    }

    /// The same +/-1% moves count for much less when they took 24h than when they took 1h.
    function test_delayedSnapshotsDoNotInflateVol() public {
        PricingEngine hourly = _engine();
        PricingEngine daily = _engine();
        uint256 t = block.timestamp;
        uint256 px = 2000e18;
        vm.startPrank(keeper);
        hourly.recordSnapshot(px);
        daily.recordSnapshot(px);
        for (uint256 i; i < 10; ++i) {
            px = i % 2 == 0 ? px * 101 / 100 : px * 100 / 101;
            vm.warp(t + (i + 1) * 1 hours);
            hourly.recordSnapshot(px);
        }
        px = 2000e18;
        for (uint256 i; i < 10; ++i) {
            px = i % 2 == 0 ? px * 101 / 100 : px * 100 / 101;
            vm.warp(t + (i + 1) * 1 days);
            daily.recordSnapshot(px);
        }
        vm.stopPrank();
        // variance rate scales 1/dt => vol ratio ~ sqrt(24)
        assertApproxEqRel(hourly.rawVolatility() * 1e18 / daily.rawVolatility(), 4.899e18, 0.02e18);
    }

    function test_strikeSolverIsCheap() public {
        PricingEngine e = _engine();
        uint256 g = gasleft();
        e.strikeForDelta(2000e18, 0.8e18, 7 days, 0.3e18);
        uint256 used = g - gasleft();
        assertLt(used, 500_000); // was ~1.3M with the strike-space bisection
    }

    function test_strikeSolverRejectsBadInputs() public {
        PricingEngine e = _engine();
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        e.strikeForDelta(0, 1e18, 7 days, 0.3e18);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        e.strikeForDelta(2000e18, 0, 7 days, 0.3e18);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        e.strikeForDelta(2000e18, 1e18, 0, 0.3e18);
    }

    function test_constructorRejectsZeroKeeper() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        new PricingEngine(address(0), 1 hours, 24, 0, 0.3e18, 5e18);
    }
}

/// Oracle liveness and keeper resilience.
contract StackHardeningTest is StackBase {
    function setUp() public {
        _deployStack();
    }

    // ---- oracle outage cannot lock collateral forever ----

    function test_staleAtExpiryAcceptedAfterFallbackDelay() public {
        IOptionsVault.Epoch memory e = _toActive();
        // feed silent for the whole epoch: last round is days before expiry
        uint80 last = feed.latestId();
        (,,, uint256 lastUpdated,) = feed.latestRoundData();
        assertGt(e.expiry - lastUpdated, HEARTBEAT + BUFFER);

        vm.warp(e.expiry + FALLBACK - 1);
        vm.expectRevert();
        resolver.submitExpiryRound(1, last); // still refused inside the delay

        vm.warp(e.expiry + FALLBACK + 1);
        uint256 price = resolver.submitExpiryRound(1, last);
        assertEq(price, uint256(px) * 1e10);

        vault.beginSettlement();
        vault.settle();
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Idle));
    }

    // ---- Chainlink phase change between last pre-expiry round and its successor ----

    function test_phaseChangeSuccessorIsRecognised() public {
        IOptionsVault.Epoch memory e = _toActive();
        vm.warp(e.expiry - 30 minutes);
        feed.push(2600e8);
        uint80 lastOfPhase0 = feed.latestId();
        vm.warp(e.expiry + 10 minutes);
        feed.pushWithId((uint80(1) << 64) | 1, 9000e8, block.timestamp); // first round of phase 1
        vm.warp(e.expiry + 1 hours);

        // successor across the phase boundary lies after expiry => lastOfPhase0 is valid
        assertEq(resolver.submitExpiryRound(1, lastOfPhase0), 2600e18);
    }

    function test_phaseChangeStillRejectsEarlierRound() public {
        IOptionsVault.Epoch memory e = _toActive();
        vm.warp(e.expiry - 2 hours);
        feed.push(2100e8);
        uint80 earlier = feed.latestId();
        vm.warp(e.expiry - 30 minutes);
        feed.push(2600e8);
        vm.warp(e.expiry + 10 minutes);
        feed.pushWithId((uint80(1) << 64) | 1, 9000e8, block.timestamp);
        vm.warp(e.expiry + 1 hours);
        vm.expectRevert(ISettlementResolver.NotLastRoundBeforeExpiry.selector);
        resolver.submitExpiryRound(1, earlier);
    }

    function test_invalidSequencerRoundRejected() public {
        sequencer.pushAt(0, 0); // startedAt == 0 => invalid round
        vm.expectRevert(ISettlementResolver.InvalidPrice.selector);
        resolver.spot();
    }

    function test_resolverConstructorAndWiringChecks() public {
        vm.expectRevert(ISettlementResolver.ZeroAddress.selector);
        new SettlementResolver(
            AggregatorV3Interface(address(0)), AggregatorV3Interface(address(0)), 1, 1, 1, 1
        );
        SettlementResolver fresh = new SettlementResolver(
            AggregatorV3Interface(address(feed)), AggregatorV3Interface(address(0)), 1, 1, 1, 1
        );
        vm.expectRevert(ISettlementResolver.ZeroAddress.selector);
        fresh.setVault(IOptionsVault(address(0)));
        vm.expectRevert(ISettlementResolver.VaultNotSet.selector);
        fresh.submitExpiryRound(1, 1);
    }

    // ---- keeper ----

    function _decode(bytes memory performData)
        internal
        pure
        returns (VaultKeeper.Action a, bytes memory d)
    {
        (a, d) = abi.decode(performData, (VaultKeeper.Action, bytes));
    }

    function test_keeperFindsExpiryRoundBeyondLinearLookback() public {
        IOptionsVault.Epoch memory e = _toActive();
        vm.warp(e.expiry - 30 minutes);
        feed.push(2600e8);
        uint80 want = feed.latestId();
        // 250 later rounds after expiry: beyond the 100-round linear scan
        for (uint256 i; i < 250; ++i) {
            vm.warp(e.expiry + 1 minutes + i * 30);
            feed.push(3000e8);
        }
        (bool need, bytes memory pd) = kc.checkUpkeep("");
        assertTrue(need);
        (VaultKeeper.Action a, bytes memory d) = _decode(pd);
        assertEq(uint8(a), uint8(VaultKeeper.Action.SubmitRound));
        assertEq(abi.decode(d, (uint80)), want);

        vm.prank(forwarder);
        kc.performUpkeep(pd);
        assertEq(resolver.snapshotSettlementPrice(1), 2600e18);
    }

    function test_keeperRespectsIdleWindow() public {
        _deposit(alice, 10e18);
        _tickUntil(IOptionsVault.State.Writing);
        vm.warp(block.timestamp + WRITING + 1);
        feed.push(px);
        // nobody bought: activation skips the epoch and reopens Idle
        _upkeep();
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Idle));
        // right now the keeper must not start another epoch
        (, bytes memory pd) = kc.checkUpkeep("");
        (VaultKeeper.Action a,) = _decode(pd);
        assertTrue(a != VaultKeeper.Action.StartEpoch);
        assertEq(vault.currentEpoch(), 1);
        // after the idle window it does
        _tickUntil(IOptionsVault.State.Writing);
        assertEq(vault.currentEpoch(), 2);
    }

    function test_keeperTakesFreshSnapshotBeforeStartingEpoch() public {
        _deposit(alice, 10e18);
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _pushFeed();
            (, bytes memory pd) = kc.checkUpkeep("");
            (VaultKeeper.Action a,) = _decode(pd);
            // whenever a snapshot is due it must come before any epoch start
            if (a == VaultKeeper.Action.StartEpoch) {
                assertLt(block.timestamp, engine.lastTimestamp() + engine.sampleInterval());
            }
            _upkeep();
        }
        assertEq(vault.currentEpoch() >= 1, true);
    }

    /// A lifecycle action that keeps reverting must not starve the vol window.
    function test_failingActionStillRecordsDueSnapshot() public {
        _deposit(alice, 10e18);
        _tickUntil(IOptionsVault.State.Writing);
        _buy(buyer, 4e18); // partially sold: Activate only due after the window
        vm.warp(block.timestamp + WRITING + 1); // both Activate and a snapshot are now due
        feed.push(px);

        vm.mockCallRevert(address(vault), abi.encodeWithSelector(vault.activate.selector), "boom");
        uint256 before_ = engine.lastTimestamp();

        (, bytes memory pd) = kc.checkUpkeep("");
        (VaultKeeper.Action a,) = _decode(pd);
        assertEq(uint8(a), uint8(VaultKeeper.Action.Activate));

        vm.prank(forwarder);
        kc.performUpkeep(pd); // fallback snapshot succeeds
        assertGt(engine.lastTimestamp(), before_);
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Writing)); // activate still pending

        // now no snapshot is due, so the failure bubbles (Automation will not send the tx)
        (, pd) = kc.checkUpkeep("");
        (a,) = _decode(pd);
        assertEq(uint8(a), uint8(VaultKeeper.Action.Activate));
        vm.prank(forwarder);
        vm.expectRevert();
        kc.performUpkeep(pd);
    }

    function test_executeIsNotPubliclyCallable() public {
        vm.prank(attacker);
        vm.expectRevert(VaultKeeper.NotSelf.selector);
        kc.execute(VaultKeeper.Action.Settle, "");
    }
}
