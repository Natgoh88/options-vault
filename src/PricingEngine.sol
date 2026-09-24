// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SD59x18, sd, unwrap, exp, ln, sqrt} from "@prb/math/src/SD59x18.sol";
import {IPricingEngine} from "./interfaces/IPricingEngine.sol";

/// @title PricingEngine
/// @notice Realized-volatility tracker (O(1) accumulators over a ring buffer) and fixed-point
///         Black-Scholes call pricer. Holds no funds.
/// @dev Normal CDF uses the Abramowitz & Stegun 26.2.17 rational approximation, absolute error
///      bounded by 7.5e-8. All values are 1e18 fixed-point.
///
///      Volatility estimator: zero-mean realized variance rate,
///          sigma^2 = sum(r_i^2) / sum(dt_i)   (per year)
///      where r_i is the log return over a snapshot gap of dt_i seconds. Weighting by the actual
///      gap (instead of assuming a fixed interval) means a delayed snapshot does not inflate vol:
///      a 1% move over 24h counts for far less than a 1% move over 1h.
contract PricingEngine is IPricingEngine {
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant DELTA_SEARCH_ITERS = 48;
    int256 internal constant D_BOUND = 8e18; // N(-8) ~ 6e-16, N(8) ~ 1 - 6e-16

    // A&S 26.2.17 constants (1e18)
    int256 internal constant AS_P = 0.2316419e18;
    int256 internal constant AS_B1 = 0.31938153e18;
    int256 internal constant AS_B2 = -0.356563782e18;
    int256 internal constant AS_B3 = 1.781477937e18;
    int256 internal constant AS_B4 = -1.821255978e18;
    int256 internal constant AS_B5 = 1.330274429e18;
    int256 internal constant INV_SQRT_2PI = 0.398942280401432678e18;

    address public immutable keeper;
    /// @notice Minimum seconds between snapshots.
    uint256 public immutable sampleInterval;
    uint256 public immutable windowSize;
    /// @notice Risk-free rate, annualised, 1e18 (e.g. 0.05e18).
    int256 public immutable riskFreeRate;
    /// @notice Bounds applied to the realized-vol estimate used for pricing. The floor keeps a flat
    ///         market (zero realized vol) from making epochs impossible to start or underpricing
    ///         options; the cap keeps a single price spike from producing an absurd strike.
    uint256 public immutable minVolatility;
    uint256 public immutable maxVolatility;

    // ring buffers of squared log returns and their time gaps
    uint256[] internal _sqReturns;
    uint256[] internal _gaps;
    uint256 internal _head; // next write slot
    uint256 internal _count; // samples in window
    uint256 internal _sumSq; // sum of squared returns (1e18)
    uint256 internal _sumGap; // sum of gaps (seconds)

    uint256 public lastPrice;
    uint256 public lastTimestamp;

    constructor(
        address keeper_,
        uint256 sampleInterval_,
        uint256 windowSize_,
        int256 riskFree_,
        uint256 minVol_,
        uint256 maxVol_
    ) {
        if (keeper_ == address(0)) revert InvalidInput();
        if (sampleInterval_ == 0 || windowSize_ < 2) revert InvalidInput();
        if (minVol_ == 0 || maxVol_ <= minVol_) revert InvalidInput();
        keeper = keeper_;
        sampleInterval = sampleInterval_;
        windowSize = windowSize_;
        riskFreeRate = riskFree_;
        minVolatility = minVol_;
        maxVolatility = maxVol_;
        _sqReturns = new uint256[](windowSize_);
        _gaps = new uint256[](windowSize_);
    }

    // ------------------------------------------------------------------
    // Volatility
    // ------------------------------------------------------------------

    /// @inheritdoc IPricingEngine
    function recordSnapshot(uint256 spot) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (spot == 0) revert InvalidInput();

        uint256 prev = lastPrice;
        if (prev != 0) {
            uint256 gap = block.timestamp - lastTimestamp;
            if (gap < sampleInterval) revert InvalidInput();
            uint256 rSq = _sq(unwrap(ln(sd(int256(spot)) / sd(int256(prev)))));

            if (_count == windowSize) {
                _sumSq -= _sqReturns[_head];
                _sumGap -= _gaps[_head];
            } else {
                _count++;
            }
            _sqReturns[_head] = rSq;
            _gaps[_head] = gap;
            _sumSq += rSq;
            _sumGap += gap;
            _head = (_head + 1) % windowSize;
        }
        lastPrice = spot;
        lastTimestamp = block.timestamp;
        emit SnapshotRecorded(_head, spot, block.timestamp);
    }

    /// @inheritdoc IPricingEngine
    /// @dev Raw estimate clamped to [minVolatility, maxVolatility].
    function realizedVolatility() public view returns (uint256) {
        uint256 v = rawVolatility();
        if (v < minVolatility) return minVolatility;
        if (v > maxVolatility) return maxVolatility;
        return v;
    }

    /// @notice Unclamped annualised realized volatility (1e18).
    function rawVolatility() public view returns (uint256) {
        if (_count < 2) revert InsufficientHistory();
        uint256 annualVar = _sumSq * SECONDS_PER_YEAR / _sumGap;
        return uint256(unwrap(sqrt(sd(int256(annualVar)))));
    }

    function sampleCount() external view returns (uint256) {
        return _count;
    }

    function _sq(int256 x) internal pure returns (uint256) {
        return uint256(unwrap(sd(x) * sd(x)));
    }

    // ------------------------------------------------------------------
    // Black-Scholes
    // ------------------------------------------------------------------

    /// @inheritdoc IPricingEngine
    function callPrice(uint256 spot, uint256 strike, uint256 vol, uint256 timeToExpiry)
        public
        view
        returns (uint256)
    {
        (int256 d1, int256 d2) = _d1d2(spot, strike, vol, timeToExpiry);
        SD59x18 disc = exp(-(sd(riskFreeRate) * sd(_years(timeToExpiry))));
        SD59x18 price = sd(int256(spot)) * sd(_cdf(d1)) - sd(int256(strike)) * disc * sd(_cdf(d2));
        int256 p = unwrap(price);
        return p > 0 ? uint256(p) : 0;
    }

    /// @inheritdoc IPricingEngine
    function callDelta(uint256 spot, uint256 strike, uint256 vol, uint256 timeToExpiry)
        public
        view
        returns (uint256)
    {
        (int256 d1,) = _d1d2(spot, strike, vol, timeToExpiry);
        return uint256(_cdf(d1));
    }

    /// @inheritdoc IPricingEngine
    /// @dev Invert delta = N(d1) by bisecting on d1 (cheap: no ln/sqrt per step), then recover the
    ///      strike in closed form from d1 = [ln(S/K) + (r + v^2/2) T] / (v sqrt(T)):
    ///          K = S * exp((r + v^2/2) T - d1 * v * sqrt(T)).
    ///      No strike bracket, so extreme vol / tenor combinations still resolve.
    function strikeForDelta(uint256 spot, uint256 vol, uint256 timeToExpiry, uint256 targetDelta)
        external
        view
        returns (uint256 strike)
    {
        if (spot == 0 || vol == 0 || timeToExpiry == 0) revert InvalidInput();
        if (targetDelta == 0 || targetDelta >= 1e18) revert InvalidInput();

        int256 lo = -D_BOUND;
        int256 hi = D_BOUND;
        int256 target = int256(targetDelta);
        for (uint256 i; i < DELTA_SEARCH_ITERS; ++i) {
            int256 mid = (lo + hi) / 2;
            if (_cdf(mid) < target) lo = mid;
            else hi = mid;
        }
        int256 d1 = (lo + hi) / 2;

        SD59x18 t = sd(_years(timeToExpiry));
        SD59x18 v = sd(int256(vol));
        SD59x18 exponent = (sd(riskFreeRate) + v * v / sd(2e18)) * t - sd(d1) * v * sqrt(t);
        int256 k = unwrap(sd(int256(spot)) * exp(exponent));
        if (k <= 0) revert InvalidInput();
        strike = uint256(k);
    }

    /// @dev seconds -> years, 1e18
    function _years(uint256 secs) internal pure returns (int256) {
        return int256(secs * 1e18 / SECONDS_PER_YEAR);
    }

    function _d1d2(uint256 spot, uint256 strike, uint256 vol, uint256 timeToExpiry)
        internal
        view
        returns (int256 d1, int256 d2)
    {
        if (spot == 0 || strike == 0 || vol == 0 || timeToExpiry == 0) revert InvalidInput();
        SD59x18 t = sd(_years(timeToExpiry));
        SD59x18 v = sd(int256(vol));
        SD59x18 volSqrtT = v * sqrt(t);
        SD59x18 num =
            ln(sd(int256(spot)) / sd(int256(strike))) + (sd(riskFreeRate) + v * v / sd(2e18)) * t;
        SD59x18 d1_ = num / volSqrtT;
        d1 = unwrap(d1_);
        d2 = unwrap(d1_ - volSqrtT);
    }

    /// @notice Standard normal CDF, A&S 26.2.17. |error| <= 7.5e-8.
    function cdf(int256 x) external pure returns (uint256) {
        return uint256(_cdf(x));
    }

    function _cdf(int256 x) internal pure returns (int256) {
        bool neg = x < 0;
        SD59x18 ax = sd(neg ? -x : x);
        // beyond 8 sigma the tail is < 1e-15
        if (unwrap(ax) > 8e18) return neg ? int256(0) : int256(1e18);

        SD59x18 t = sd(1e18) / (sd(1e18) + sd(AS_P) * ax);
        // Horner evaluation of t*(b1 + t*(b2 + t*(b3 + t*(b4 + t*b5)))), one step at a time
        SD59x18 poly = sd(AS_B5);
        poly = sd(AS_B4) + t * poly;
        poly = sd(AS_B3) + t * poly;
        poly = sd(AS_B2) + t * poly;
        poly = sd(AS_B1) + t * poly;
        poly = t * poly;
        SD59x18 pdf = sd(INV_SQRT_2PI) * exp(-(ax * ax) / sd(2e18));
        int256 upper = unwrap(pdf * poly); // upper tail 1 - N(|x|)
        return neg ? upper : 1e18 - upper;
    }
}
