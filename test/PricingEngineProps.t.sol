// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PricingEngine} from "../src/PricingEngine.sol";

/// Reference-vector, property, edge-case and ring-buffer tests for PricingEngine.
contract PricingEngineProps is Test {
    PricingEngine engine;
    address keeper = address(0xBEEF);

    uint256 constant CDF_ERR = 75e9; // A&S 26.2.17 bound, 7.5e-8 in 1e18

    function setUp() public {
        engine = new PricingEngine(keeper, 1 hours, 24, 0.05e18, 0.3e18, 5e18);
    }

    // ------------------------------------------------------------------
    // Reference vectors (script/gen_vectors.py, exact CDF via erfc)
    // ------------------------------------------------------------------

    function test_referenceVectors() public view {
        string memory json = vm.readFile("test/vectors/bs_vectors.json");
        uint256[] memory spot = vm.parseJsonUintArray(json, ".spot");
        uint256[] memory strike = vm.parseJsonUintArray(json, ".strike");
        uint256[] memory vol = vm.parseJsonUintArray(json, ".vol");
        uint256[] memory secs = vm.parseJsonUintArray(json, ".secs");
        uint256[] memory price = vm.parseJsonUintArray(json, ".price");
        uint256[] memory delta = vm.parseJsonUintArray(json, ".delta");
        assertEq(spot.length, 400);

        for (uint256 i; i < spot.length; ++i) {
            uint256 got = engine.callPrice(spot[i], strike[i], vol[i], secs[i]);
            // Error budget: A&S error on N(d1) scaled by S and on N(d2) scaled by K*e^-rT,
            // plus a small allowance for fixed-point ln/exp/sqrt rounding.
            uint256 bound = (spot[i] + strike[i]) * CDF_ERR / 1e18 + spot[i] / 1e6;
            assertApproxEqAbs(got, price[i], bound, "price");

            uint256 gotDelta = engine.callDelta(spot[i], strike[i], vol[i], secs[i]);
            assertApproxEqAbs(gotDelta, delta[i], CDF_ERR + 1e10, "delta");
        }
    }

    // ------------------------------------------------------------------
    // Properties
    // ------------------------------------------------------------------

    function testFuzz_priceDecreasingInStrike(uint256 k1, uint256 k2, uint256 vol, uint256 secs)
        public
        view
    {
        vol = bound(vol, 0.1e18, 3e18);
        secs = bound(secs, 1 hours, 365 days);
        k1 = bound(k1, 1000e18, 4000e18);
        k2 = bound(k2, k1, 4000e18);
        uint256 p1 = engine.callPrice(2000e18, k1, vol, secs);
        uint256 p2 = engine.callPrice(2000e18, k2, vol, secs);
        assertGe(p1 + 5e12, p2);
    }

    function testFuzz_priceIncreasingInSpot(uint256 s1, uint256 s2, uint256 vol, uint256 secs)
        public
        view
    {
        vol = bound(vol, 0.1e18, 3e18);
        secs = bound(secs, 1 hours, 365 days);
        s1 = bound(s1, 1000e18, 4000e18);
        s2 = bound(s2, s1, 4000e18);
        assertGe(
            engine.callPrice(s2, 2000e18, vol, secs) + 5e12,
            engine.callPrice(s1, 2000e18, vol, secs)
        );
    }

    function testFuzz_deltaDecreasingInStrike(uint256 k1, uint256 k2, uint256 vol, uint256 secs)
        public
        view
    {
        vol = bound(vol, 0.1e18, 3e18);
        secs = bound(secs, 1 hours, 365 days);
        k1 = bound(k1, 1000e18, 4000e18);
        k2 = bound(k2, k1, 4000e18);
        assertGe(
            engine.callDelta(2000e18, k1, vol, secs) + CDF_ERR,
            engine.callDelta(2000e18, k2, vol, secs)
        );
    }

    /// No-arbitrage bounds: C <= S, and C >= S - K (r >= 0 so S - K e^{-rT} >= S - K), up to error.
    function testFuzz_priceWithinArbBounds(uint256 k, uint256 vol, uint256 secs) public view {
        vol = bound(vol, 0.05e18, 5e18);
        secs = bound(secs, 1, 5 * 365 days);
        k = bound(k, 500e18, 8000e18);
        uint256 s = 2000e18;
        uint256 p = engine.callPrice(s, k, vol, secs);
        uint256 slack = (s + k) * CDF_ERR / 1e18 + 1e12;
        assertLe(p, s + slack);
        if (s > k) assertGe(p + slack, s - k);
    }

    function testFuzz_cdfBoundedMonotoneSymmetric(int256 x, int256 y) public view {
        x = bound(x, -10e18, 10e18);
        y = bound(y, x, 10e18);
        uint256 nx = engine.cdf(x);
        assertLe(nx, 1e18);
        assertGe(engine.cdf(y) + CDF_ERR, nx);
        // Exact symmetry by construction, except at x == 0 where the polynomial has a ~1e-9
        // discontinuity (within the A&S bound).
        assertApproxEqAbs(nx + engine.cdf(-x), 1e18, x == 0 ? CDF_ERR : 2);
    }

    function testFuzz_strikeForDeltaRoundTrip(uint256 vol, uint256 secs, uint256 target)
        public
        view
    {
        vol = bound(vol, 0.3e18, 1.5e18);
        secs = bound(secs, 1 days, 30 days);
        target = bound(target, 0.1e18, 0.9e18);
        uint256 k = engine.strikeForDelta(2000e18, vol, secs, target);
        assertApproxEqAbs(engine.callDelta(2000e18, k, vol, secs), target, 1e12);
    }

    // ------------------------------------------------------------------
    // Edge cases
    // ------------------------------------------------------------------

    function test_extremeInputsDoNotRevert() public view {
        engine.callPrice(2000e18, 1000e18, 0.5e18, 1);
        engine.callPrice(2000e18, 8000e18, 0.5e18, 1);
        uint256 p = engine.callPrice(2000e18, 2000e18, 5e18, 5 * 365 days);
        assertLe(p, 2000e18);
        engine.callPrice(1, 1, 0.5e18, 7 days);
    }

    function test_zeroInputsRevert() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.callPrice(0, 1e18, 1e18, 1 days);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.callPrice(1e18, 0, 1e18, 1 days);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.callPrice(1e18, 1e18, 0, 1 days);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.callPrice(1e18, 1e18, 1e18, 0);
    }

    /// Documented limitation: the bisection bracket is [S/4, 4S]; a target delta whose strike
    /// falls outside it (here 10-delta at 300% vol, 60d) reverts rather than returning garbage.
    function test_strikeForDeltaOutsideBracketReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.strikeForDelta(2000e18, 3e18, 60 days, 0.1e18);
    }

    function test_strikeForDeltaBadTargetReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.strikeForDelta(2000e18, 0.5e18, 7 days, 0);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.strikeForDelta(2000e18, 0.5e18, 7 days, 1e18);
    }

    function test_insufficientHistoryReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InsufficientHistory()"));
        engine.realizedVolatility();
        vm.startPrank(keeper);
        engine.recordSnapshot(2000e18);
        vm.warp(block.timestamp + 1 hours);
        engine.recordSnapshot(2010e18); // one return only
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSignature("InsufficientHistory()"));
        engine.realizedVolatility();
    }

    function test_snapshotTooSoonReverts() public {
        vm.startPrank(keeper);
        engine.recordSnapshot(2000e18);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        engine.recordSnapshot(2010e18);
        vm.stopPrank();
    }

    function test_constructorRejectsBadParams() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        new PricingEngine(keeper, 0, 24, 0, 0.3e18, 5e18);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        new PricingEngine(keeper, 1 hours, 1, 0, 0.3e18, 5e18);
    }

    // ------------------------------------------------------------------
    // Ring buffer / accumulator correctness
    // ------------------------------------------------------------------

    function _feed(PricingEngine e, uint256[] memory prices) internal {
        uint256 t = block.timestamp;
        vm.startPrank(keeper);
        for (uint256 i; i < prices.length; ++i) {
            vm.warp(t + i * 1 hours);
            e.recordSnapshot(prices[i]);
        }
        vm.stopPrank();
    }

    /// After the window wraps, vol must equal that of a fresh engine that only saw the last
    /// `window` returns, i.e. evicted samples leave no residue in the accumulators.
    function test_ringBufferWraparoundMatchesFreshWindow() public {
        PricingEngine a = new PricingEngine(keeper, 1 hours, 4, 0.05e18, 0.3e18, 5e18);
        PricingEngine b = new PricingEngine(keeper, 1 hours, 4, 0.05e18, 0.3e18, 5e18);
        uint256[11] memory raw =
            [uint256(2000), 2300, 1700, 2600, 1500, 2000, 2020, 1990, 2040, 2010, 2050];
        uint256[] memory all = new uint256[](11);
        for (uint256 i; i < 11; ++i) {
            all[i] = raw[i] * 1e18;
        }
        _feed(a, all);
        uint256[] memory tail = new uint256[](5); // 5 prices => 4 returns
        for (uint256 i; i < 5; ++i) {
            tail[i] = all[6 + i];
        }
        _feed(b, tail);
        assertEq(a.sampleCount(), 4);
        assertApproxEqRel(a.rawVolatility(), b.rawVolatility(), 1e10);
    }

    /// Accumulator drift: after many wraps, still matches a fresh engine on the last window.
    function testFuzz_accumulatorNoDrift(uint256 seed) public {
        uint256 w = 8;
        uint256 n = 60;
        PricingEngine a = new PricingEngine(keeper, 1 hours, w, 0.05e18, 0.3e18, 5e18);
        PricingEngine b = new PricingEngine(keeper, 1 hours, w, 0.05e18, 0.3e18, 5e18);
        uint256[] memory prices = new uint256[](n);
        uint256 px = 2000e18;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            px = px * (900 + (seed % 201)) / 1000; // 0.9x .. 1.1x per step
            prices[i] = px;
        }
        _feed(a, prices);
        uint256[] memory tail = new uint256[](w + 1);
        for (uint256 i; i < w + 1; ++i) {
            tail[i] = prices[n - (w + 1) + i];
        }
        _feed(b, tail);
        assertApproxEqRel(a.rawVolatility(), b.rawVolatility(), 1e11);
    }

    // ------------------------------------------------------------------
    // Volatility clamp (regression: flat market => zero vol froze epoch start)
    // ------------------------------------------------------------------

    function test_flatMarketVolClampedToFloor() public {
        vm.startPrank(keeper);
        for (uint256 i; i < 12; ++i) {
            engine.recordSnapshot(2000e18); // identical prices => zero returns
            vm.warp(block.timestamp + 1 hours);
        }
        vm.stopPrank();
        assertEq(engine.rawVolatility(), 0);
        assertEq(engine.realizedVolatility(), engine.minVolatility());
        // and the floor keeps strike selection working
        engine.strikeForDelta(2000e18, engine.realizedVolatility(), 7 days, 0.3e18);
    }

    function test_spikeVolClampedToCap() public {
        vm.startPrank(keeper);
        engine.recordSnapshot(2000e18);
        vm.warp(block.timestamp + 1 hours);
        engine.recordSnapshot(4000e18); // +100% in an hour
        vm.warp(block.timestamp + 1 hours);
        engine.recordSnapshot(2000e18);
        vm.stopPrank();
        assertGt(engine.rawVolatility(), engine.maxVolatility());
        assertEq(engine.realizedVolatility(), engine.maxVolatility());
        engine.strikeForDelta(2000e18, engine.realizedVolatility(), 7 days, 0.3e18);
    }

    function test_constructorRejectsBadVolBounds() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        new PricingEngine(keeper, 1 hours, 24, 0, 0, 5e18);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        new PricingEngine(keeper, 1 hours, 24, 0, 1e18, 1e18);
    }
}
