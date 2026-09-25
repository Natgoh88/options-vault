import { fmtDateTime, fmtDuration, fmtNum, fmtPct, fmtToken, fmtUsd, toNum } from "../format";
import { STATES, type Snapshot } from "../vault";

const STAGES = [
  { name: "Idle", cap: "Deposits and withdrawals open" },
  { name: "Writing", cap: "Options on sale" },
  { name: "Active", cap: "Collateral locked" },
  { name: "Settling", cap: "Recording settlement price" },
];

export function EpochPanel({ snap, now }: { snap?: Snapshot; now: number }) {
  if (!snap) {
    return (
      <section className="panel">
        <div className="panel-h">
          <h2>Epoch</h2>
        </div>
        <div className="empty">Loading…</div>
      </section>
    );
  }

  const cur = snap.current;
  const live = snap.state !== 0 && cur && !cur.settled;
  const strike = live ? cur!.strike : snap.greeksStrike;
  const spot = snap.spot !== undefined ? toNum(snap.spot) : NaN;
  const strikeN = strike !== undefined ? toNum(strike) : NaN;

  // headline countdown
  let headline = "";
  if (snap.state === 0) {
    const open = snap.idleSince + snap.idleWindow;
    headline =
      now < open
        ? `Exit window: next epoch cannot start for ${fmtDuration(open - now)}`
        : snap.sampleCount < 2
          ? "Waiting for volatility history before the next epoch"
          : "Next epoch starts on the next keeper run";
  } else if (snap.state === 1 && cur) {
    headline = `Sale closes in ${fmtDuration(cur.writingEnd - now)}`;
  } else if (snap.state === 2 && cur) {
    headline = now < cur.expiry ? `Expires in ${fmtDuration(cur.expiry - now)}` : "Expired, awaiting settlement";
  } else if (snap.state === 3) {
    headline = "Settlement price recorded, finalising";
  }

  const premiumUsd = live ? toNum(cur!.premiumPerOption, 6) : NaN;
  const sold = live ? toNum(cur!.optionsSold) : 0;
  const locked = live ? toNum(cur!.collateralLocked) : 0;
  const soldPct = locked > 0 ? sold / locked : 0;
  const refSpot = live ? toNum(cur!.spotAtStart) : spot;

  return (
    <section className="panel">
      <div className="panel-h">
        <h2>{live ? `Epoch #${cur!.id}` : "Next epoch"}</h2>
        <span className="pill">
          <span className={`dot ${snap.state === 2 ? "pos" : snap.state === 0 ? "" : "amber"}`} />
          {STATES[snap.state]}
        </span>
      </div>
      <div className="panel-b">
        <div className="steps" role="list" aria-label="Epoch lifecycle">
          {STAGES.map((s, i) => (
            <div key={s.name} role="listitem" className={`step ${i < snap.state ? "done" : i === snap.state ? "now" : ""}`}>
              <span className="node" />
              <div className="name">{s.name}</div>
              <div className="cap">{s.cap}</div>
            </div>
          ))}
        </div>

        <p className="note num" style={{ marginTop: 20, color: "var(--text-2)" }}>
          {headline}
        </p>

        <div className="kv">
          <div>
            <div className="label">{live ? "Strike" : "Indicative strike"}</div>
            <div className="v num">{Number.isFinite(strikeN) ? fmtUsd(strikeN) : "—"}</div>
            <div className="s num">
              {Number.isFinite(strikeN) && Number.isFinite(refSpot) && refSpot > 0
                ? `${fmtNum((strikeN / refSpot - 1) * 100, 1)}% above spot`
                : `${fmtNum(toNum(snap.targetDelta) * 100, 0)}-delta target`}
            </div>
          </div>
          <div>
            <div className="label">Premium per WETH</div>
            <div className="v num">
              {live
                ? fmtUsd(premiumUsd)
                : snap.fair !== undefined
                  ? fmtUsd(toNum(snap.fair) * (1 + snap.markupBps / 10000))
                  : "—"}
            </div>
            <div className="s num">
              {live && refSpot > 0
                ? `${fmtPct(premiumUsd / refSpot, 2)} of spot`
                : `fair value + ${fmtNum(snap.markupBps / 100, 1)}% margin`}
            </div>
          </div>
          <div>
            <div className="label">Options sold</div>
            <div className="v num">{live ? `${fmtNum(soldPct * 100, 0)}%` : "—"}</div>
            <div className="bar" aria-hidden="true">
              <i style={{ width: `${soldPct * 100}%` }} />
              {snap.minFillBps > 0 && <b style={{ left: `${snap.minFillBps / 100}%` }} title="Minimum fill" />}
            </div>
            <div className="s num">
              {live ? `${fmtNum(snap.minFillBps / 100, 0)}% needed or the epoch is cancelled` : `min fill ${fmtNum(snap.minFillBps / 100, 0)}%`}
            </div>
          </div>
          <div>
            <div className="label">Collateral</div>
            <div className="v num">{live ? fmtToken(cur!.collateralLocked, 18, 4) : fmtToken(snap.totalAssets, 18, 4)}</div>
            <div className="s">WETH{live ? " locked" : " available"}</div>
          </div>
          <div>
            <div className="label">Spot at start</div>
            <div className="v num">{live ? fmtUsd(toNum(cur!.spotAtStart)) : Number.isFinite(spot) ? fmtUsd(spot) : "—"}</div>
            <div className="s">{live ? "quotes valid within " + fmtNum(snap.maxDeviationBps / 100, 1) + "%" : "live Chainlink price"}</div>
          </div>
          <div>
            <div className="label">Expiry</div>
            <div className="v num">{live ? fmtDateTime(cur!.expiry) : `${fmtDuration(snap.epochDuration)} epoch`}</div>
            <div className="s">{live ? "local time" : "from start of sale"}</div>
          </div>
        </div>
      </div>
    </section>
  );
}
