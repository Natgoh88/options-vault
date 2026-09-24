import { useMemo, useRef, useState } from "react";
import { fmtNum, fmtUsd, toNum } from "../format";
import type { Snapshot } from "../vault";

const W = 720;
const H = 288;
const M = { l: 56, r: 16, t: 20, b: 32 };

function niceTicks(min: number, max: number, count = 5): number[] {
  const span = max - min;
  const raw = span / count;
  const pow = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * pow).find((s) => s >= raw) ?? raw;
  const out: number[] = [];
  for (let v = Math.ceil(min / step) * step; v <= max + 1e-9; v += step) out.push(Math.round(v / step) * step);
  return out;
}

const signed = (n: number) => (n >= 0 ? "+" : "−") + fmtUsd(Math.abs(n));

/**
 * P&L at expiry for 1 WETH held by the vault with one call written against it, versus simply
 * holding. Depositors keep the premium and give up everything above the strike.
 */
export function PayoffChart({ snap }: { snap?: Snapshot }) {
  const ref = useRef<SVGSVGElement>(null);
  const [hover, setHover] = useState<number>();

  const live = snap && snap.state !== 0 && snap.current && !snap.current.settled ? snap.current : undefined;
  const spotNow = snap?.spot !== undefined ? toNum(snap.spot) : NaN;

  const model = useMemo(() => {
    if (!snap) return undefined;
    const entry = live ? toNum(live.spotAtStart) : spotNow;
    const strike = live ? toNum(live.strike) : snap.greeksStrike !== undefined ? toNum(snap.greeksStrike) : NaN;
    const premium = live
      ? toNum(live.premiumPerOption, 6)
      : snap.fair !== undefined
        ? toNum(snap.fair) * (1 + snap.markupBps / 10000)
        : NaN;
    if (![entry, strike, premium].every(Number.isFinite)) return undefined;

    // Show +/- ~3.5 standard deviations of the epoch's own move, so the shape is legible for a
    // 6-hour demo epoch and a 7-day production one alike. Always keep the strike in view.
    const sigmaT = snap.vol !== undefined ? toNum(snap.vol) * Math.sqrt(snap.epochDuration / (365 * 86400)) : 0.1;
    const half = Math.min(0.4, Math.max(0.025, 3.5 * sigmaT, (strike / entry - 1) * 1.6));
    const xMin = entry * (1 - half);
    const xMax = entry * (1 + half);
    const hodl = (p: number) => p - entry;
    const cc = (p: number) => p - entry + premium - Math.max(p - strike, 0);
    const yMin = Math.min(hodl(xMin), cc(xMin));
    const yMax = Math.max(hodl(xMax), cc(xMax));
    const pad = (yMax - yMin) * 0.06;
    return { entry, strike, premium, xMin, xMax, yMin: yMin - pad, yMax: yMax + pad, hodl, cc };
  }, [snap, live, spotNow]);

  if (!model) {
    return (
      <section className="panel">
        <div className="panel-h">
          <h2>Payoff at expiry</h2>
        </div>
        <div className="empty">{snap ? "Waiting for volatility history to price the next epoch." : "Loading…"}</div>
      </section>
    );
  }

  const { entry, strike, premium, xMin, xMax, yMin, yMax, hodl, cc } = model;
  const x = (p: number) => M.l + ((p - xMin) / (xMax - xMin)) * (W - M.l - M.r);
  const y = (v: number) => M.t + (1 - (v - yMin) / (yMax - yMin)) * (H - M.t - M.b);
  const xTicks = niceTicks(xMin, xMax, 6);
  const yTicks = niceTicks(yMin, yMax, 5);

  const probe = hover ?? (Number.isFinite(spotNow) ? spotNow : entry);
  const probeC = Math.min(Math.max(probe, xMin), xMax);
  const ccV = cc(probeC);
  const hodlV = hodl(probeC);

  const onMove = (e: React.MouseEvent<SVGSVGElement>) => {
    const r = ref.current!.getBoundingClientRect();
    const px = ((e.clientX - r.left) / r.width) * W;
    const p = xMin + ((px - M.l) / (W - M.l - M.r)) * (xMax - xMin);
    setHover(Math.min(Math.max(p, xMin), xMax));
  };

  const breakeven = entry - premium;

  return (
    <section className="panel">
      <div className="panel-h">
        <h2>Payoff at expiry</h2>
        <span className="hint">Per 1 WETH deposited, versus holding</span>
      </div>
      <div className="panel-b">
        <div className="readout num" aria-live="off">
          <div>
            <div className="label">ETH at expiry</div>
            <div className="r">{fmtUsd(probeC, 0)}</div>
          </div>
          <div>
            <div className="label">Vault P&amp;L</div>
            <div className={`r ${ccV >= 0 ? "pos" : "neg"}`}>{signed(ccV)}</div>
          </div>
          <div>
            <div className="label">Holding P&amp;L</div>
            <div className={`r ${hodlV >= 0 ? "" : "neg"}`} style={{ color: hodlV >= 0 ? "var(--text-2)" : undefined }}>
              {signed(hodlV)}
            </div>
          </div>
        </div>

        <svg
          ref={ref}
          className="chart"
          viewBox={`0 0 ${W} ${H}`}
          role="img"
          aria-label="Covered call payoff compared with holding"
          onMouseMove={onMove}
          onMouseLeave={() => setHover(undefined)}
        >
          {yTicks.map((t) => (
            <g key={"y" + t}>
              <line className={t === 0 ? "axis-l" : "grid-l"} x1={M.l} x2={W - M.r} y1={y(t)} y2={y(t)} />
              <text x={M.l - 10} y={y(t) + 4} textAnchor="end">
                {t < 0 ? "−" : ""}${fmtNum(Math.abs(t), 0)}
              </text>
            </g>
          ))}
          {xTicks.map((t) => (
            <text key={"x" + t} x={x(t)} y={H - 8} textAnchor="middle">
              ${fmtNum(t, 0)}
            </text>
          ))}

          {/* strike */}
          <line className="mark" x1={x(strike)} x2={x(strike)} y1={M.t} y2={H - M.b} />
          <text className="tag" x={x(strike) + 6} y={M.t + 8}>
            Strike {fmtUsd(strike, 0)}
          </text>

          {/* breakeven */}
          {breakeven > xMin && breakeven < xMax && (
            <>
              <circle cx={x(breakeven)} cy={y(0)} r="3" fill="var(--bg)" stroke="var(--text-2)" strokeWidth="1.25" />
              <text className="tag" x={x(breakeven) - 8} y={y(0) - 10} textAnchor="end">
                Breakeven {fmtUsd(breakeven, 0)}
              </text>
            </>
          )}

          {/* lines */}
          <path className="hodl" d={`M${x(xMin)} ${y(hodl(xMin))} L${x(xMax)} ${y(hodl(xMax))}`} />
          <path
            className="cc"
            d={`M${x(xMin)} ${y(cc(xMin))} L${x(Math.min(strike, xMax))} ${y(cc(Math.min(strike, xMax)))} L${x(xMax)} ${y(cc(xMax))}`}
          />

          {/* live spot */}
          {Number.isFinite(spotNow) && spotNow >= xMin && spotNow <= xMax && (
            <>
              <line className="spot-l" x1={x(spotNow)} x2={x(spotNow)} y1={M.t} y2={H - M.b} />
              <text className="tag-strong" x={x(spotNow) - 6} y={M.t + 8} textAnchor="end">
                Spot {fmtUsd(spotNow, 0)}
              </text>
            </>
          )}

          {/* probe */}
          <line className="mark" x1={x(probeC)} x2={x(probeC)} y1={M.t} y2={H - M.b} style={{ opacity: hover === undefined ? 0 : 1 }} />
          <circle cx={x(probeC)} cy={y(ccV)} r="4" fill="var(--text)" />
        </svg>

        <div className="legend">
          <span>
            <i />
            Vault (premium kept, upside capped at strike)
          </span>
          <span>
            <i className="d" />
            Holding WETH
          </span>
        </div>
      </div>
    </section>
  );
}
