// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsVault} from "../src/OptionsVault.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {IPricingEngine} from "../src/interfaces/IPricingEngine.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {ISettlementResolver} from "../src/interfaces/ISettlementResolver.sol";
import {VaultBase} from "./OptionsVault.t.sol";

/// Minimum-fill cancellation (post-Phase-5 audit, finding A-1) and option-id uniqueness (A-2).
contract CancellationTest is VaultBase {
    function setUp() public {
        _deploy();
    }

    function _closeWriting() internal {
        vm.warp(vault.epochData(vault.currentEpoch()).writingEnd + 1);
        vault.activate();
    }

    /// Exploit (A-1): before the fix, buying 1 wei of options for ~1e-6 USDC stopped the unsold
    /// epoch from being skipped and locked every depositor's WETH for a full epoch.
    function test_exploit_dustPurchaseCannotLockVault() public {
        uint256 shares = _deposit(alice, 10e18);
        _start();
        uint256 cost = _buy(buyer, 1);
        assertLe(cost, 1); // the attack costs one USDC base unit
        _closeWriting();

        // the epoch is cancelled rather than activated: collateral is free immediately
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Idle));
        assertTrue(vault.epochData(1).cancelled);
        vm.prank(alice);
        assertEq(vault.redeem(shares, alice, alice), 10e18);
    }

    function test_underFilledEpochRefundsBuyersAndPaysNoPremium() public {
        _deposit(alice, 10e18);
        _start();
        uint256 cost = _buy(buyer, 0.9e18); // 9% < 10% minimum
        uint256 before = usdc.balanceOf(buyer);
        _closeWriting();

        IOptionsVault.Epoch memory e = vault.epochData(1);
        assertTrue(e.cancelled && e.settled);
        assertEq(vault.pendingPremium(alice), 0, "premium must not accrue to shareholders");
        assertEq(vault.reservedPayout(), 0);

        vm.prank(buyer);
        uint256 refund = vault.redeemOptions(1, 0.9e18);
        assertApproxEqAbs(refund, cost, 1); // rounds down by at most one base unit
        assertLe(refund, cost);
        assertEq(usdc.balanceOf(buyer), before + refund);
        assertEq(token.balanceOf(buyer, token.tokenId(e.strike, e.expiry)), 0);
    }

    function test_exactlyMinimumFillGoesAhead() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 1e18); // exactly 10%
        _closeWriting();
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Active));
        assertFalse(vault.epochData(1).cancelled);
    }

    function test_partialRefundsAndCannotRefundTwice() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 0.5e18);
        _closeWriting();
        vm.startPrank(buyer);
        vault.redeemOptions(1, 0.2e18);
        vault.redeemOptions(1, 0.3e18);
        vm.expectRevert(); // tokens already burned
        vault.redeemOptions(1, 1);
        vm.stopPrank();
    }

    function test_refundIsNonReentrantAndTransferable() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 0.5e18);
        IOptionsVault.Epoch memory e = vault.epochData(1);
        uint256 id = token.tokenId(e.strike, e.expiry);
        vm.prank(buyer);
        token.safeTransferFrom(buyer, bob, id, 0.5e18, "");
        _closeWriting();
        vm.prank(bob);
        assertGt(vault.redeemOptions(1, 0.5e18), 0);
    }

    /// A-2: idleWindow == 0 would let a cancelled epoch and the next one start in the same block
    /// with the same (strike, expiry), so their option tokens would share an id.
    function test_zeroIdleWindowRejected() public {
        OptionsVault.Params memory p = OptionsVault.Params({
            epochDuration: EPOCH,
            writingWindow: WRITING,
            idleWindow: 0,
            targetDelta: 0.3e18,
            maxSpotDeviationBps: MAX_DEV_BPS,
            premiumMarkupBps: MARKUP_BPS,
            minFillBps: MIN_FILL_BPS
        });
        vm.expectRevert(IOptionsVault.InvalidParams.selector);
        new OptionsVault(
            IERC20(address(weth)),
            IERC20(address(usdc)),
            IPricingEngine(address(engine)),
            ISettlementResolver(address(resolver)),
            IOptionToken(address(token)),
            keeper,
            p
        );
        p.idleWindow = IDLE;
        p.minFillBps = 10_001;
        vm.expectRevert(IOptionsVault.InvalidParams.selector);
        new OptionsVault(
            IERC20(address(weth)),
            IERC20(address(usdc)),
            IPricingEngine(address(engine)),
            ISettlementResolver(address(resolver)),
            IOptionToken(address(token)),
            keeper,
            p
        );
    }

    /// Consecutive epochs (including after a cancellation, at an unchanged spot) never share an
    /// option token id.
    function test_optionIdsUniqueAcrossEpochs() public {
        _deposit(alice, 10e18);
        uint256[] memory ids = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            vm.warp(vault.idleSince() + IDLE);
            _start();
            IOptionsVault.Epoch memory e = vault.epochData(vault.currentEpoch());
            ids[i] = token.tokenId(e.strike, e.expiry);
            _closeWriting(); // nothing sold: cancelled straight back to Idle
            for (uint256 j; j < i; ++j) {
                assertTrue(ids[i] != ids[j], "option id reused");
            }
        }
    }
}
