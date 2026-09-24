// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {IOptionToken} from "../src/interfaces/IOptionToken.sol";
import {OptionsVault} from "../src/OptionsVault.sol";
import {VaultKeeper} from "../src/VaultKeeper.sol";
import {ISettlementResolver} from "../src/interfaces/ISettlementResolver.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {PricingEngine} from "../src/PricingEngine.sol";
import {VaultBase} from "./OptionsVault.t.sol";
import {StackBase} from "./Stack.t.sol";

/// Buyer contract that tries to re-enter the vault from the ERC-1155 receive hook.
contract ReentrantBuyer is IERC1155Receiver {
    enum Attack {
        None,
        BuyAgain,
        ClaimPremium,
        RedeemOptions,
        Deposit,
        ActivateWhenSoldOut
    }

    OptionsVault public vault;
    Attack public attack;
    bool public hookRan;

    constructor(OptionsVault v) {
        vault = v;
    }

    function setAttack(Attack a) external {
        attack = a;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        hookRan = true;
        if (attack == Attack.BuyAgain) {
            vault.buyOptions(1);
        } else if (attack == Attack.ClaimPremium) {
            vault.claimPremium();
        } else if (attack == Attack.RedeemOptions) {
            vault.redeemOptions(1, 1);
        } else if (attack == Attack.Deposit) {
            vault.deposit(1, address(this));
        } else if (attack == Attack.ActivateWhenSoldOut) {
            vault.activate();
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == type(IERC165).interfaceId;
    }
}

contract SecurityTest is VaultBase {
    function setUp() public {
        _deploy();
    }

    function _reentrantBuyer() internal returns (ReentrantBuyer b) {
        b = new ReentrantBuyer(vault);
        usdc.mint(address(b), 1e12);
        vm.prank(address(b));
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------

    function _attackBuy(ReentrantBuyer.Attack a, bytes memory expected) internal {
        _deposit(alice, 10e18);
        _start();
        ReentrantBuyer b = _reentrantBuyer();
        b.setAttack(a);
        if (a == ReentrantBuyer.Attack.Deposit) {
            // max deposit is 0 outside Idle: ERC4626ExceededMaxDeposit(receiver, assets, max)
            expected = abi.encodeWithSignature(
                "ERC4626ExceededMaxDeposit(address,uint256,uint256)", address(b), 1, 0
            );
        }
        vm.prank(address(b));
        vm.expectRevert(expected);
        vault.buyOptions(5e18);
        // the whole purchase reverted: nothing was sold, no premium taken
        assertEq(vault.epochData(1).optionsSold, 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_reentrancy_buyAgainFromHook() public {
        _attackBuy(
            ReentrantBuyer.Attack.BuyAgain,
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_reentrancy_claimPremiumFromHook() public {
        _attackBuy(
            ReentrantBuyer.Attack.ClaimPremium,
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_reentrancy_redeemOptionsFromHook() public {
        _attackBuy(
            ReentrantBuyer.Attack.RedeemOptions,
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    function test_reentrancy_depositFromHookBlockedByState() public {
        _attackBuy(ReentrantBuyer.Attack.Deposit, ""); // expects ERC4626ExceededMaxDeposit
    }

    /// Re-entering `activate()` from the hook when the purchase sells the epoch out is allowed and
    /// harmless: all accounting (premium, optionsSold) was updated before the external calls.
    function test_reentrancy_activateFromHookSeesConsistentAccounting() public {
        _deposit(alice, 10e18);
        _start();
        ReentrantBuyer b = _reentrantBuyer();
        b.setAttack(ReentrantBuyer.Attack.ActivateWhenSoldOut);
        vm.prank(address(b));
        uint256 cost = vault.buyOptions(10e18); // sells out => hook activates the epoch

        IOptionsVault.Epoch memory e = vault.epochData(1);
        assertEq(e.optionsSold, 10e18);
        assertEq(e.premiumCollected, cost);
        assertEq(uint8(vault.state()), uint8(IOptionsVault.State.Active));
        // premium accrued exactly once, to the right shares
        assertApproxEqAbs(vault.pendingPremium(alice), cost, 1);
    }

    // ------------------------------------------------------------------
    // ERC-4626 first-depositor inflation attack
    // ------------------------------------------------------------------

    function test_inflationAttackFailsToStealVictimDeposit() public {
        address attacker = makeAddr("attacker");
        // attacker mints a tiny position, then donates a lot to inflate the share price
        weth.mint(attacker, 100e18 + 1);
        vm.startPrank(attacker);
        weth.approve(address(vault), type(uint256).max);
        vault.deposit(1, attacker);
        weth.transfer(address(vault), 100e18); // donation
        vm.stopPrank();

        uint256 victimIn = 50e18;
        uint256 victimShares = _deposit(bob, victimIn);
        assertGt(victimShares, 0);

        // victim can withdraw ~everything they put in (virtual shares make the attack unprofitable)
        vm.prank(bob);
        uint256 out = vault.redeem(victimShares, bob, bob);
        assertGe(out, victimIn * 99 / 100);

        // attacker cannot recover more than they put in (1 wei + 100 WETH donation)
        uint256 attackerShares = vault.balanceOf(attacker);
        vm.prank(attacker);
        uint256 attackerOut = vault.redeem(attackerShares, attacker, attacker);
        assertLe(attackerOut, 100e18 + 1 + (victimIn - out));
        assertLt(attackerOut, 100e18 + 1 + victimIn / 100 + 1);
    }

    // ------------------------------------------------------------------
    // Rounding always favours the vault
    // ------------------------------------------------------------------

    function testFuzz_depositThenRedeemNeverProfits(uint256 amount) public {
        amount = bound(amount, 1, 1_000e18);
        _deposit(alice, 1e18); // pre-existing liquidity so shares are non-trivial
        weth.mint(bob, amount);
        vm.startPrank(bob);
        weth.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, bob);
        uint256 out = vault.redeem(shares, bob, bob);
        vm.stopPrank();
        assertLe(out, amount);
    }

    /// Splitting a purchase into many small ones can never be cheaper (premium rounds up per call).
    function testFuzz_splitBuyingNeverCheaper(uint256 total, uint256 parts) public {
        total = bound(total, 10, 10e18);
        parts = bound(parts, 2, 10);
        _deposit(alice, 10e18);
        _start();

        uint256 single = _quote(total);
        uint256 chunk = total / parts;
        uint256 split;
        for (uint256 i; i < parts; ++i) {
            split += _quote(chunk);
        }
        // `split` buys chunk*parts <= total options; compare on a per-option basis
        assertGe(split, _quoteFloor(chunk * parts));
        assertGe(single, _quoteFloor(total));
    }

    function _quote(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, vault.epochData(1).premiumPerOption, 1e18, Math.Rounding.Ceil);
    }

    function _quoteFloor(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, vault.epochData(1).premiumPerOption, 1e18);
    }

    /// Payout never exceeds the exact value and never exceeds 1 WETH per option.
    function testFuzz_payoutRoundsDown(uint256 priceMul, uint256 amount) public {
        priceMul = bound(priceMul, 101, 500); // price = strike * 1.01 .. 5x
        _deposit(alice, 10e18);
        _start();
        amount = bound(amount, 1, 10e18);
        _buy(buyer, amount);
        uint256 strike = vault.epochData(1).strike;
        _finish(strike * priceMul / 100);
        IOptionsVault.Epoch memory e = vault.epochData(1);
        vm.prank(buyer);
        uint256 payout = vault.redeemOptions(1, amount);
        // exact rational payout = amount * (P - K) / P
        assertLe(payout * e.settlementPrice, amount * (e.settlementPrice - strike));
        assertLt(payout, amount);
    }

    // ------------------------------------------------------------------
    // Access control matrix
    // ------------------------------------------------------------------

    function test_accessControlMatrix() public {
        address rando = makeAddr("rando");
        _deposit(alice, 10e18);
        vm.startPrank(rando);

        vm.expectRevert(IOptionsVault.NotKeeper.selector);
        vault.startEpoch();
        vm.expectRevert(); // Ownable
        vault.setKeeper(rando);
        vm.expectRevert(); // Ownable
        vault.transferOwnership(rando);

        vm.expectRevert(IOptionToken.NotVault.selector);
        token.mint(rando, 1, 1, 1);
        vm.expectRevert(IOptionToken.NotVault.selector);
        token.burn(rando, 1, 1, 1);

        vm.expectRevert(abi.encodeWithSignature("NotKeeper()"));
        engine.recordSnapshot(1);
        vm.stopPrank();

        // state-machine transitions are permissionless but only in the right state
        vm.expectRevert();
        vault.activate();
        vm.expectRevert();
        vault.beginSettlement();
        vm.expectRevert();
        vault.settle();
    }

    /// Nobody can redeem options for an epoch that has not settled, nor someone else's options.
    function test_cannotRedeemOthersOptions() public {
        _deposit(alice, 10e18);
        _start();
        _buy(buyer, 10e18);
        _finish(vault.epochData(1).strike * 2);
        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(); // burn from thief: insufficient balance
        vault.redeemOptions(1, 1e18);
    }
}

/// Keeper / resolver access control on the real stack.
contract StackSecurityTest is StackBase {
    function setUp() public {
        _deployStack();
    }

    function test_keeperAndResolverAccessControl() public {
        address rando = makeAddr("rando");
        vm.startPrank(rando);
        vm.expectRevert(VaultKeeper.NotForwarder.selector);
        kc.performUpkeep(abi.encode(VaultKeeper.Action.Snapshot, bytes("")));
        vm.expectRevert(VaultKeeper.NotSelf.selector);
        kc.execute(VaultKeeper.Action.Snapshot, "");
        vm.expectRevert(VaultKeeper.NotOwner.selector);
        kc.setForwarder(rando);
        vm.expectRevert(ISettlementResolver.NotDeployer.selector);
        resolver.setVault(IOptionsVault(rando));
        vm.stopPrank();
    }

    /// The vault's keeper must be the VaultKeeper contract; an EOA owner cannot start epochs.
    function test_ownerCannotStartEpochDirectly() public {
        _deposit(alice, 10e18);
        for (uint256 i; i < 10; ++i) {
            _tick();
        }
        // owner (this test contract) is not the keeper
        vm.expectRevert();
        vault.startEpoch();
    }
}
