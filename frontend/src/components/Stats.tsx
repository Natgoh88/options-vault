import { fmtDuration, fmtNum, fmtPct, fmtToken, fmtUsd, toNum } from "../format";
import { STATES, type Snapshot } from "../vault";

const Skel = () => <span className="skeleton" />;

/** Premium collected / collateral at the time, for the most recent epoch that sold options. */
export function lastEpochYield(snap: Snapshot): { yield: number; annualised?: number } | undefined {
  const e = snap.epochs.find((x) => x.settled && !x.cancelled && x.optionsSold > 0n);
  if (!e) return undefined;
  const premiumUsd = toNum(e.premiumCollected, 6);
  const collateralUsd = toNum(e.collateralLocked) * toNum(e.spotAtStart);
  if (!collateralUsd) return undefined;
  const y = premiumUsd / collateralUsd;
  // Annualising a sub-day epoch produces meaningless four-digit percentages; only do it for
  // epochs of at least three days (the production weekly cadence).
  const annualised = snap.epochDuration >= 3 * 86400 ? y * ((365 * 86400) / snap.epochDuration) : undefined;
  return { yield: y, annualised };
}

export function Stats({ snap, now }: { snap?: Snapshot; now: number }) {
  const spot = snap?.spot !== undefined ? toNum(snap.spot) : NaN;
  const tvl = snap ? toNum(snap.totalAssets) : NaN;
  const y = snap ? lastEpochYield(snap) : undefined;
  const cur = snap?.current;

  let epochSub = "No epoch yet";
  if (snap && cur && !cur.settled) {
    if (snap.state === 2) epochSub = now < cur.expiry ? `Expires in ${fmtDuration(cur.expiry - now)}` : "Awaiting settlement";
    else if (snap.state === 1) epochSub = `Sale closes in ${fmtDuration(cur.writingEnd - now)}`;
    else epochSub = "Settling";
  } else if (snap && snap.currentEpoch > 0) {
    epochSub = "Last epoch settled";
  }

  return (
    <section className="stats" aria-label="Vault summary">
      <div className="stat">
        <div className="label">Total value locked</div>
        <div className="value num">
          {snap ? fmtToken(snap.totalAssets, 18, 4) : <Skel />}
          <small>WETH</small>
        </div>
        <div className="sub num">{snap && Number.isFinite(spot) ? fmtUsd(tvl * spot, 0) : " "}</div>
      </div>

      <div className="stat">
        <div className="label">ETH / USD</div>
        <div className="value num">{Number.isFinite(spot) ? fmtUsd(spot) : snap ? "Stale" : <Skel />}</div>
        <div className="sub">
          Chainlink
          {snap?.vol !== undefined && <span className="num"> {"·"} realized vol {fmtPct(toNum(snap.vol), 1)}</span>}
        </div>
      </div>

      <div className="stat">
        <div className="label">Epoch</div>
        <div className="value num">
          {snap ? (snap.currentEpoch > 0 ? `#${snap.currentEpoch}` : "—") : <Skel />}
          {snap && <small>{STATES[snap.state]}</small>}
        </div>
        <div className="sub num">{snap ? epochSub : " "}</div>
      </div>

      <div className="stat">
        <div className="label">Premium yield, last epoch</div>
        <div className="value num">{y ? fmtPct(y.yield, 2) : snap ? "—" : <Skel />}</div>
        <div className="sub num">{y ? (y.annualised !== undefined ? `${fmtNum(y.annualised * 100, 1)}% annualised` : `per ${fmtDuration(snap!.epochDuration)} epoch`) : "No settled epoch with sales"}</div>
      </div>
    </section>
  );
}
