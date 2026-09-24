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
        vol = bound(vol, 0.1e18, 5e18);
        secs = bound(secs, 1 hours, 90 days);
        target = bound(target, 0.02e18, 0.98e18);
        uint256 k = engine.strikeForDelta(2000e18, vol, secs, target);
        assertApproxEqAbs(engine.callDelta(2000e18, k, vol, secs), target, 1e13);
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

    /// Regression: the old solver bisected over [S/4, 4S] and reverted for extreme vol/tenor
    /// (10-delta at 300% vol, 60d). The d1-space solver has no strike bracket.
    function test_strikeForDeltaExtremeInputsResolve() public view {
        uint256 k = engine.strikeForDelta(2000e18, 3e18, 60 days, 0.1e18);
        assertGt(k, 4 * 2000e18); // beyond the old bracket
        assertApproxEqAbs(engine.callDelta(2000e18, k, 3e18, 60 days), 0.1e18, 1e12);
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

    // ------------------------------------------------------------------
    // Greeks
    // ------------------------------------------------------------------

    /// All 400 reference vectors, Greeks computed with exact closed forms in Python.
    function test_greeksReferenceVectors() public view {
        string memory json = vm.readFile("test/vectors/bs_vectors.json");
        uint256[] memory spot = vm.parseJsonUintArray(json, ".spot");
        uint256[] memory strike = vm.parseJsonUintArray(json, ".strike");
        uint256[] memory vol = vm.parseJsonUintArray(json, ".vol");
        uint256[] memory secs = vm.parseJsonUintArray(json, ".secs");
        int256[] memory gamma = vm.parseJsonIntArray(json, ".gamma");
        int256[] memory vega = vm.parseJsonIntArray(json, ".vega");
        int256[] memory theta = vm.parseJsonIntArray(json, ".theta");
        int256[] memory rho = vm.parseJsonIntArray(json, ".rho");

        for (uint256 i; i < spot.length; ++i) {
            PricingEngine.Greeks memory g = engine.callGreeks(spot[i], strike[i], vol[i], secs[i]);
            // pdf-only Greeks (gamma, vega): fixed-point rounding only
            assertApproxEqAbs(g.gamma, gamma[i], _tol(gamma[i], 0), "gamma");
            assertApproxEqAbs(g.vega, vega[i], _tol(vega[i], 0), "vega");
            // theta and rho carry the A&S CDF error through N(d2), scaled by K
            assertApproxEqAbs(g.theta, theta[i], _tol(theta[i], strike[i]), "theta");
            assertApproxEqAbs(g.rho, rho[i], _tol(rho[i], strike[i]), "rho");
            // delta agrees with callDelta exactly
            assertEq(uint256(g.delta), engine.callDelta(spot[i], strike[i], vol[i], secs[i]));
        }
    }

    function _tol(int256 expected, uint256 cdfScaled) internal pure returns (uint256) {
        uint256 mag = uint256(expected < 0 ? -expected : expected);
        return mag / 1e7 + 1e6 + cdfScaled * CDF_ERR * 2 / 1e18;
    }

    /// Sign conventions and independent finite-difference cross-checks.
    function testFuzz_greeksSignsAndFiniteDifference(uint256 vol, uint256 secs, uint256 kMul)
        public
        view
    {
        vol = bound(vol, 0.3e18, 2e18);
        secs = bound(secs, 1 days, 30 days);
        kMul = bound(kMul, 80, 130);
        uint256 s = 2000e18;
        uint256 k = s * kMul / 100;

        PricingEngine.Greeks memory g = engine.callGreeks(s, k, vol, secs);
        assertGe(g.gamma, 0);
        assertGe(g.vega, 0);
        assertLe(g.theta, 0); // r >= 0: a long call always decays
        assertGe(g.rho, 0);

        assertApproxEqAbs(g.delta, _fdDelta(s, k, vol, secs), 5e15); // 0.5%: CDF error / 2h
        // Finite differences of prices carry the CDF error: (S+K)*7.5e-8*2 / (2*dv) ~ 0.3 USD per
        // unit vol, so allow that as an absolute floor on top of a 5% relative band.
        assertApproxEqAbs(g.vega, _fdVega(s, k, vol, secs), uint256(g.vega) / 20 + 0.5e18);
    }

    /// delta ~ (C(S+h) - C(S-h)) / 2h
    function _fdDelta(uint256 s, uint256 k, uint256 vol, uint256 secs)
        internal
        view
        returns (int256)
    {
        uint256 h = s / 1000;
        int256 up = int256(engine.callPrice(s + h, k, vol, secs));
        int256 dn = int256(engine.callPrice(s - h, k, vol, secs));
        return (up - dn) * 1e18 / int256(2 * h);
    }

    /// vega ~ (C(v+dv) - C(v-dv)) / 2dv
    function _fdVega(uint256 s, uint256 k, uint256 vol, uint256 secs)
        internal
        view
        returns (int256)
    {
        uint256 dv = 1e15;
        int256 up = int256(engine.callPrice(s, k, vol + dv, secs));
        int256 dn = int256(engine.callPrice(s, k, vol - dv, secs));
        return (up - dn) * 1e18 / int256(2 * dv);
    }

    function test_constructorRejectsBadVolBounds() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        new PricingEngine(keeper, 1 hours, 24, 0, 0, 5e18);
        vm.expectRevert(abi.encodeWithSignature("InvalidInput()"));
        new PricingEngine(keeper, 1 hours, 24, 0, 1e18, 1e18);
    }
}
