// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {VaultBase} from "./OptionsVault.t.sol";

/// Drives random sequences of deposits, epochs, purchases, settlements and redemptions.
contract VaultHandler is Test {
    VaultBase.Deployment internal d;

    address[] public actors;

    // ghost accounting
    mapping(uint256 => uint256) public paidOut; // epoch => WETH paid to option holders
    uint256 public premiumIn; // USDC paid by buyers
    uint256 public premiumClaimed; // USDC claimed by shareholders
    uint256 public epochsStarted;

    constructor(VaultBase.Deployment memory d_) {
        d = d_;
        for (uint256 i; i < 3; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _state() internal view returns (IOptionsVault.State) {
        return d.vault.state();
    }

    function deposit(uint256 seed, uint256 amount) external {
        if (_state() != IOptionsVault.State.Idle) return;
        amount = bound(amount, 1e6, 100e18);
        address a = _actor(seed);
        d.weth.mint(a, amount);
        vm.startPrank(a);
        d.weth.approve(address(d.vault), amount);
        d.vault.deposit(amount, a);
        vm.stopPrank();
    }

    function redeemShares(uint256 seed, uint256 pct) external {
        if (_state() != IOptionsVault.State.Idle) return;
        address a = _actor(seed);
        uint256 bal = d.vault.balanceOf(a);
        if (bal == 0) return;
        pct = bound(pct, 1, 100);
        vm.prank(a);
        d.vault.redeem(bal * pct / 100, a, a);
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 pct) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = d.vault.balanceOf(from);
        if (bal == 0) return;
        vm.prank(from);
        d.vault.transfer(to, bal * bound(pct, 1, 100) / 100);
    }

    function startEpoch(uint256 spot) external {
        if (_state() != IOptionsVault.State.Idle) return;
        if (d.vault.totalAssets() == 0 || d.vault.totalSupply() == 0) return;
        d.resolver.setPrice(bound(spot, 1000e18, 4000e18));
        vm.prank(d.keeper);
        try d.vault.startEpoch() {
            ++epochsStarted;
        } catch {}
    }

    function buy(uint256 seed, uint256 amount) external {
        if (_state() != IOptionsVault.State.Writing) return;
        IOptionsVault.Epoch memory e = d.vault.epochData(d.vault.currentEpoch());
        if (block.timestamp > e.writingEnd) return;
        uint256 room = e.collateralLocked - e.optionsSold;
        if (room == 0) return;
        amount = bound(amount, 1, room);
        address a = _actor(seed);
        uint256 max = amount * e.premiumPerOption / 1e18 + 2;
        d.usdc.mint(a, max);
        vm.startPrank(a);
        d.usdc.approve(address(d.vault), max);
        premiumIn += d.vault.buyOptions(amount);
        vm.stopPrank();
    }

    function activate() external {
        if (_state() != IOptionsVault.State.Writing) return;
        IOptionsVault.Epoch memory e = d.vault.epochData(d.vault.currentEpoch());
        if (e.optionsSold < e.collateralLocked && block.timestamp <= e.writingEnd) {
            vm.warp(e.writingEnd + 1);
        }
        d.vault.activate();
    }

    function settle(uint256 price) external {
        if (_state() != IOptionsVault.State.Active) return;
        IOptionsVault.Epoch memory e = d.vault.epochData(d.vault.currentEpoch());
        if (block.timestamp < e.expiry) vm.warp(e.expiry);
        d.resolver.setPrice(bound(price, 200e18, 8000e18));
        d.vault.beginSettlement();
        d.vault.settle();
    }

    function redeemOptions(uint256 seed, uint256 epochSeed, uint256 pct) external {
        uint256 n = d.vault.currentEpoch();
        if (n == 0) return;
        uint256 epoch = 1 + (epochSeed % n);
        IOptionsVault.Epoch memory e = d.vault.epochData(epoch);
        if (!e.settled) return;
        address a = _actor(seed);
        uint256 id = d.token.tokenId(e.strike, e.expiry);
        uint256 bal = d.token.balanceOf(a, id);
        if (bal == 0) return;
        uint256 amt = bal * bound(pct, 1, 100) / 100;
        if (amt == 0) return;
        vm.prank(a);
        paidOut[epoch] += d.vault.redeem(epoch, amt);
    }

    function claimPremium(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        premiumClaimed += d.vault.claimPremium();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }
}

contract OptionsVaultInvariants is VaultBase {
    VaultHandler handler;

    function setUp() public {
        _deploy();
        handler = new VaultHandler(_deployment());
        targetContract(address(handler));
    }

    /// Reserved WETH is always backed by the vault's actual balance.
    function invariant_reservedPayoutBacked() public view {
        assertGe(weth.balanceOf(address(vault)), vault.reservedPayout());
    }

    /// Options sold never exceed collateral locked, and locked collateral stays in the vault
    /// for the whole epoch.
    function invariant_collateralCoversSoldOptions() public view {
        uint256 n = vault.currentEpoch();
        for (uint256 i = 1; i <= n; ++i) {
            IOptionsVault.Epoch memory e = vault.epochData(i);
            assertLe(e.optionsSold, e.collateralLocked);
        }
        if (n > 0 && vault.state() != IOptionsVault.State.Idle) {
            IOptionsVault.Epoch memory cur = vault.epochData(n);
            assertGe(vault.totalAssets(), cur.collateralLocked);
        }
    }

    /// Everything paid to option holders for an epoch is bounded by what was locked, and by
    /// the payout formula applied to options sold.
    function invariant_payoutsNeverExceedLocked() public view {
        uint256 n = vault.currentEpoch();
        for (uint256 i = 1; i <= n; ++i) {
            IOptionsVault.Epoch memory e = vault.epochData(i);
            uint256 paid = handler.paidOut(i);
            assertLe(paid, e.collateralLocked, "paid > locked");
            assertLe(paid, Math.mulDiv(e.optionsSold, e.payoutPerOption, 1e18), "paid > owed");
        }
    }

    /// Payout per option can never reach 1 WETH (call is capped by the underlying).
    function invariant_payoutPerOptionBelowOne() public view {
        uint256 n = vault.currentEpoch();
        for (uint256 i = 1; i <= n; ++i) {
            assertLt(vault.epochData(i).payoutPerOption, 1e18);
        }
    }

    /// Reserved payout covers every outstanding option's redemption value (rounded down per
    /// redemption, so reserved >= sum of individual claims).
    function invariant_reservedCoversOutstandingOptions() public view {
        uint256 owed;
        uint256 n = vault.currentEpoch();
        for (uint256 i = 1; i <= n; ++i) {
            IOptionsVault.Epoch memory e = vault.epochData(i);
            if (!e.settled) continue;
            uint256 id = token.tokenId(e.strike, e.expiry);
            for (uint256 a; a < handler.actorCount(); ++a) {
                uint256 bal = token.balanceOf(handler.actors(a), id);
                owed += Math.mulDiv(bal, e.payoutPerOption, 1e18);
            }
        }
        assertGe(vault.reservedPayout(), owed);
    }

    /// USDC held by the vault always covers all claimable premium.
    function invariant_premiumSolvent() public view {
        uint256 pending;
        for (uint256 a; a < handler.actorCount(); ++a) {
            pending += vault.pendingPremium(handler.actors(a));
        }
        assertGe(usdc.balanceOf(address(vault)), pending);
        assertLe(handler.premiumClaimed() + pending, handler.premiumIn());
    }

    /// Share supply equals the sum of actor balances.
    function invariant_sharesConserved() public view {
        uint256 sum;
        for (uint256 a; a < handler.actorCount(); ++a) {
            sum += vault.balanceOf(handler.actors(a));
        }
        assertEq(sum, vault.totalSupply());
    }
}
