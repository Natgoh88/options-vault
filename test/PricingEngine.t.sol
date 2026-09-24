// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PricingEngine} from "../src/PricingEngine.sol";

contract PricingEngineTest is Test {
    PricingEngine engine;
    address keeper = address(0xBEEF);

    function setUp() public {
        engine = new PricingEngine(keeper, 1 hours, 24, 0.05e18, 0.3e18, 5e18);
    }

    function test_cdfKnownValues() public view {
        assertApproxEqAbs(engine.cdf(0), 0.5e18, 1e11);
        assertApproxEqAbs(engine.cdf(1e18), 0.841344746068543e18, 1e11);
        assertApproxEqAbs(engine.cdf(-1e18), 0.158655253931457e18, 1e11);
        assertApproxEqAbs(engine.cdf(1.96e18), 0.97500210485178e18, 1e11);
    }

    /// S=K=100, vol 20%, T=1y, r=5% -> call 10.4506, delta 0.6368
    function test_atmCallReference() public view {
        uint256 p = engine.callPrice(100e18, 100e18, 0.2e18, 365 days);
        // CDF error <= 7.5e-8 on each of N(d1), N(d2) => price error <= ~2 * S * 7.5e-8 = 1.5e-5
        assertApproxEqAbs(p, 10.450583572e18, 1.5e13);
        uint256 d = engine.callDelta(100e18, 100e18, 0.2e18, 365 days);
        assertApproxEqAbs(d, 0.636830651e18, 1e11);
    }

    function testFuzz_priceMonotonicInVol(uint256 v1, uint256 v2) public view {
        v1 = bound(v1, 0.05e18, 3e18);
        v2 = bound(v2, v1, 3e18);
        uint256 p1 = engine.callPrice(2000e18, 2200e18, v1, 7 days);
        uint256 p2 = engine.callPrice(2000e18, 2200e18, v2, 7 days);
        assertGe(p2 + 1e9, p1);
    }

    function test_strikeForDelta() public view {
        uint256 k = engine.strikeForDelta(2000e18, 0.6e18, 7 days, 0.3e18);
        assertGt(k, 2000e18);
        assertApproxEqAbs(engine.callDelta(2000e18, k, 0.6e18, 7 days), 0.3e18, 1e12);
    }

    function test_realizedVolAlternatingMoves() public {
        // alternating +1% / -1% moves each hour
        uint256 px = 2000e18;
        vm.startPrank(keeper);
        engine.recordSnapshot(px);
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 1 hours);
            px = i % 2 == 0 ? px * 101 / 100 : px * 100 / 101;
            engine.recordSnapshot(px);
        }
        vm.stopPrank();
        uint256 vol = engine.realizedVolatility();
        // per-hour stdev ~ 1% => annual ~ 0.01 * sqrt(8760) ~ 0.936
        assertApproxEqRel(vol, 0.936e18, 0.1e18);
    }

    function test_onlyKeeper() public {
        vm.expectRevert();
        engine.recordSnapshot(1e18);
    }
}
