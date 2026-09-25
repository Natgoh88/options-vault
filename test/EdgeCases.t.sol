// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {IPricingEngine} from "../src/interfaces/IPricingEngine.sol";
import {ISettlementResolver} from "../src/interfaces/ISettlementResolver.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {OptionToken} from "../src/OptionToken.sol";
import {PricingEngine} from "../src/PricingEngine.sol";
import {SettlementResolver} from "../src/SettlementResolver.sol";
import {VaultKeeper} from "../src/VaultKeeper.sol";
import {VaultBase} from "./OptionsVault.t.sol";
import {StackBase} from "./Stack.t.sol";
import {MockAggregator} from "./mocks/Mocks.sol";

/// Edge and error paths found by the Phase 4 coverage review.
contract VaultEdgeCases is VaultBase {
    function setUp() public {
        _deploy();
    }

    function test_setKeeperRotatesKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vault.setKeeper(newKeeper);
        assertEq(vault.keeper(), newKeeper);

        _deposit(alice, 10e18);
        vm.prank(keeper); // old keeper is locked out
        vm.expectRevert(IOptionsVault.NotKeeper.selector);
        vault.startEpoch();
        vm.prank(newKeeper);
        vault.startEpoch();
        assertEq(vault.currentEpoch(), 1);
    }

    /// An epoch that would price at zero must never start (would give options away).
    function test_zeroPremiumEpochRefusesToStart() public {
        _deposit(alice, 10e18);
        vm.mockCall(
            address(engine),
            abi.encodeWithSelector(IPricingEngine.callPrice.selector),
            abi.encode(0)
        );
        vm.prank(keeper);
        vm.expectRevert(IOptionsVault.ZeroPremium.selector);
        vault.startEpoch();
    }

    function test_redeemOptionsZeroAmountReverts() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 10e18);
        _finish(vault.epochData(1).strike * 2);
        vm.prank(buyer);
        vm.expectRevert(IOptionsVault.ZeroAmount.selector);
        vault.redeemOptions(1, 0);
    }

    function test_optionTokenWiringGuards() public {
        OptionToken t = new OptionToken();
        vm.prank(makeAddr("rando"));
        vm.expectRevert(OptionToken.NotDeployer.selector);
        t.setVault(address(1));
        vm.expectRevert(OptionToken.ZeroAddress.selector);
        t.setVault(address(0));
        t.setVault(address(1));
        assertEq(t.vault(), address(1));
    }

    function test_engineRejectsZeroSpotSnapshot() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.recordSnapshot(0);
    }
}

contract StackEdgeCases is StackBase {
    function setUp() public {
        _deployStack();
    }

    function test_keeperInitRejectsZeroAddresses() public {
        VaultKeeper fresh = new VaultKeeper(1);
        vm.expectRevert(VaultKeeper.ZeroAddress.selector);
        fresh.init(
            PricingEngine(address(0)),
            IOptionsVault(address(vault)),
            resolver,
            AggregatorV3Interface(address(feed))
        );
    }

    /// Feed too stale to trust: the keeper must do nothing rather than act on bad data.
    function test_keeperIdlesWhenOracleUnhealthy() public {
        _deposit(alice, 10e18);
        vm.warp(block.timestamp + HEARTBEAT + BUFFER + 1); // no feed update: spot() reverts
        (bool need,) = kc.checkUpkeep("");
        assertFalse(need);
        // once the feed recovers the keeper resumes
        feed.push(px);
        (need,) = kc.checkUpkeep("");
        assertTrue(need);
    }

    /// Round ids with gaps (missing rounds revert in getRoundData) must not break the finder.
    function test_keeperRoundSearchToleratesMissingRounds() public {
        IOptionsVault.Epoch memory e = _toActive();
        vm.warp(e.expiry - 30 minutes);
        feed.push(2600e8);
        uint80 want = feed.latestId();
        vm.warp(e.expiry + 5 minutes);
        // sparse later rounds: ids jump, so the scan back from latest crosses non-existent ids
        feed.pushWithId(want + 40, 3000e8, block.timestamp);
        (bool need, bytes memory pd) = kc.checkUpkeep("");
        assertTrue(need);
        (VaultKeeper.Action a, bytes memory d) = abi.decode(pd, (VaultKeeper.Action, bytes));
        assertEq(uint8(a), uint8(VaultKeeper.Action.SubmitRound));
        assertEq(abi.decode(d, (uint80)), want);
    }

    function test_resolverRejectsFutureTimestampAndBadDecimals() public {
        feed.pushAt(px, block.timestamp + 1 days);
        vm.expectRevert(ISettlementResolver.InvalidPrice.selector);
        resolver.spot();

        MockAggregator weird = new MockAggregator(19);
        vm.expectRevert(ISettlementResolver.InvalidPrice.selector);
        new SettlementResolver(
            AggregatorV3Interface(address(weird)), AggregatorV3Interface(address(0)), 1, 1, 1, 1
        );
    }

    function test_settlementRoundWithNonPositiveAnswerRejected() public {
        IOptionsVault.Epoch memory e = _toActive();
        vm.warp(e.expiry - 30 minutes);
        feed.push(0);
        uint80 bad = feed.latestId();
        vm.warp(e.expiry + 1 hours);
        vm.expectRevert(ISettlementResolver.InvalidPrice.selector);
        resolver.submitExpiryRound(1, bad);
    }

    function test_forwarderCanBeRotated() public {
        address newForwarder = makeAddr("newForwarder");
        kc.setForwarder(newForwarder);
        (, bytes memory pd) = kc.checkUpkeep("");
        vm.prank(forwarder); // old forwarder locked out
        vm.expectRevert(VaultKeeper.NotForwarder.selector);
        kc.performUpkeep(pd);
    }

    /// A-3: a WETH donation to a vault with no shareholders made the keeper propose StartEpoch,
    /// which reverts (NothingToLock), every block. It must just keep taking snapshots.
    function test_keeperIgnoresDonationWithNoShareholders() public {
        weth.mint(address(vault), 1e18);
        for (uint256 i; i < 12; ++i) {
            _tick();
        }
        assertEq(vault.currentEpoch(), 0);
        assertGe(engine.sampleCount(), 6);
    }
}
