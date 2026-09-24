import { fmtDuration, fmtNum, fmtPct, fmtUsd, toNum } from "../format";
import type { Snapshot } from "../vault";

export function GreeksPanel({ snap }: { snap?: Snapshot }) {
  const g = snap?.greeks;
  const spot = snap?.spot !== undefined ? toNum(snap.spot) : NaN;
  const strike = snap?.greeksStrike !== undefined ? toNum(snap.greeksStrike) : NaN;
  const vol = snap?.vol !== undefined ? toNum(snap.vol) : NaN;
  const fair = snap?.fair !== undefined ? toNum(snap.fair) : NaN;
  const charged =
    snap?.current && !snap.indicative
      ? toNum(snap.current.premiumPerOption, 6)
      : Number.isFinite(fair)
        ? fair * (1 + (snap?.markupBps ?? 0) / 10000)
        : NaN;

  // Raw values are per unit; scale to the conventional trading units. Theta is quoted per hour
  // for epochs shorter than two days, where "per day" would overstate a same-day decay.
  const shortDated = (snap?.greeksSeconds ?? 0) < 2 * 86400;
  const thetaDiv = shortDated ? 365 * 24 : 365;
  const cells = g
    ? [
        { k: "Delta", v: fmtNum(toNum(g.delta), 3), u: "per $1 in ETH" },
        { k: "Gamma", v: fmtNum(toNum(g.gamma), 5), u: "delta per $1 in ETH" },
        { k: "Vega", v: fmtUsd(toNum(g.vega) / 100), u: "per 1 vol point" },
        { k: "Theta", v: fmtUsd(toNum(g.theta) / thetaDiv), u: shortDated ? "per hour" : "per day" },
        { k: "Rho", v: fmtUsd(toNum(g.rho) / 100), u: "per 1% rate" },
      ]
    : [];

  return (
    <section className="panel">
      <div className="panel-h">
        <h2>Greeks</h2>
        <span className="hint">
          {snap?.indicative ? "Indicative, next epoch" : "Live epoch"} {"·"} computed on-chain
        </span>
      </div>
      <div className="panel-b">
        {!snap ? (
          <div className="empty">Loading{"…"}</div>
        ) : !g ? (
          <div className="empty" style={{ padding: "24px 0" }}>
            Volatility window warming up ({snap.sampleCount} samples). Greeks appear once the engine has enough history.
          </div>
        ) : (
          <>
            <div className="greeks">
              {cells.map((c) => (
                <div key={c.k}>
                  <div className="label">{c.k}</div>
                  <div className="g num">{c.v}</div>
                  <div className="u">{c.u}</div>
                </div>
              ))}
            </div>
            <div className="inputs num">
              <div>
                <span>Spot</span>
                <span>{fmtUsd(spot)}</span>
              </div>
              <div>
                <span>Strike</span>
                <span>{fmtUsd(strike)}</span>
              </div>
              <div>
                <span>Realized vol</span>
                <span>{fmtPct(vol, 1)}</span>
              </div>
              <div>
                <span>Time to expiry</span>
                <span>{snap.greeksSeconds ? fmtDuration(snap.greeksSeconds) : "—"}</span>
              </div>
              <div>
                <span>Fair value now</span>
                <span>{fmtUsd(fair)}</span>
              </div>
              <div>
                <span>Premium charged</span>
                <span>{fmtUsd(charged)}</span>
              </div>
            </div>
          </>
        )}
        <p className="note" style={{ marginTop: g ? 36 : 12 }}>
          Values come straight from <span className="mono">PricingEngine.callGreeks</span>, using the same fixed-point
          Black-Scholes as the premium. Volatility is the contract{"’"}s own realized-vol estimate; the normal CDF is an
          Abramowitz-Stegun approximation with error below 7.5e-8.
        </p>
      </div>
    </section>
  );
}
