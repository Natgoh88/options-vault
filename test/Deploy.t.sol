// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {TestUSDC} from "../src/testnet/TestUSDC.sol";
import {IOptionsVault} from "../src/interfaces/IOptionsVault.sol";
import {MockERC20, MockAggregator} from "./mocks/Mocks.sol";

/// Runs the real deploy script against mocks and checks the resulting wiring, so a mistake in
/// the script (wrong argument order, missing one-shot wiring call) fails here, not on a testnet.
contract DeployScriptTest is Test {
    // Each test uses its own scratch chain id so its deployments/<id>.json never collides with
    // another test (tests run in parallel) or with a real deployment file.
    uint256 constant SCRATCH_CHAIN = 999_000;

    function _deployWith(string memory profile, uint256 chainOffset)
        internal
        returns (Deploy.Deployed memory d)
    {
        uint256 id = SCRATCH_CHAIN + chainOffset;
        vm.chainId(id);
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        MockAggregator feed = new MockAggregator(8);
        feed.push(2000e8);
        d = new Deploy().deployWith(profile, address(weth), address(feed), address(0), address(0));
        vm.removeFile(string.concat("./deployments/", vm.toString(id), ".json"));
    }

    function test_demoProfileWiring() public {
        Deploy.Deployed memory d = _deployWith("demo", 1);

        // contracts reference each other correctly
        assertEq(d.vault.keeper(), address(d.keeper));
        assertEq(d.engine.keeper(), address(d.keeper));
        assertEq(d.token.vault(), address(d.vault));
        assertEq(address(d.resolver.vault()), address(d.vault));
        assertEq(address(d.keeper.engine()), address(d.engine));
        assertEq(address(d.keeper.vault()), address(d.vault));
        assertEq(address(d.keeper.resolver()), address(d.resolver));
        assertEq(address(d.vault.usdc()), d.usdc);

        // the demo profile: hours-long epochs
        assertEq(d.vault.epochDuration(), 6 hours);
        assertEq(d.vault.writingWindow(), 30 minutes);
        assertEq(d.vault.idleWindow(), 30 minutes);
        assertEq(d.engine.sampleInterval(), 10 minutes);
        assertEq(d.engine.windowSize(), 36);
        assertEq(d.keeper.minSamples(), 6);
        assertEq(d.vault.targetDelta(), 0.3e18);

        // one-shot wiring really is one-shot
        vm.expectRevert();
        d.token.setVault(address(1));
        vm.expectRevert();
        d.resolver.setVault(IOptionsVault(address(1)));
    }

    function test_weeklyProfileIsProductionCadence() public {
        Deploy.Deployed memory d = _deployWith("weekly", 2);
        assertEq(d.vault.epochDuration(), 7 days);
        assertEq(d.vault.idleWindow(), 1 days);
        assertEq(d.vault.maxSpotDeviationBps(), 100);
        assertEq(d.engine.sampleInterval(), 1 hours);
        assertEq(d.engine.windowSize(), 168);
        assertEq(d.keeper.minSamples(), 24);
        assertEq(d.resolver.heartbeat(), 1 days);
    }

    function test_deploymentIsOwnedByDeployerNotZero() public {
        Deploy.Deployed memory d = _deployWith("demo", 3);
        assertTrue(d.vault.owner() != address(0));
        assertEq(d.keeper.owner(), d.vault.owner());
    }
}

contract TestUSDCTest is Test {
    TestUSDC usdc;
    address user = makeAddr("user");

    function setUp() public {
        usdc = new TestUSDC();
    }

    function test_sixDecimalsAndFaucetAmount() public {
        assertEq(usdc.decimals(), 6);
        vm.prank(user);
        usdc.faucet();
        assertEq(usdc.balanceOf(user), 10_000e6);
    }

    function test_faucetIsRateLimitedPerAddress() public {
        vm.startPrank(user);
        usdc.faucet();
        vm.expectRevert(
            abi.encodeWithSelector(TestUSDC.FaucetCooldown.selector, block.timestamp + 1 hours)
        );
        usdc.faucet();
        vm.warp(block.timestamp + 1 hours);
        usdc.faucet();
        assertEq(usdc.balanceOf(user), 20_000e6);
        vm.stopPrank();

        // another address is independent
        vm.prank(makeAddr("other"));
        usdc.faucet();
    }
}
