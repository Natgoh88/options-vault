import { fmtPct, fmtToken, fmtUsd, toNum } from "../format";
import type { Epoch, Snapshot } from "../vault";

function outcome(e: Epoch): { label: string; cls: string } {
  if (!e.settled) return { label: "Live", cls: "" };
  if (e.cancelled) return { label: e.optionsSold === 0n ? "No sale" : "Cancelled", cls: "faint" };
  return e.payoutPerOption > 0n ? { label: "ITM", cls: "neg" } : { label: "OTM", cls: "pos" };
}

export function History({ snap }: { snap?: Snapshot }) {
  const rows = snap?.epochs ?? [];
  return (
    <section className="panel">
      <div className="panel-h">
        <h2>Epoch history</h2>
        <span className="hint">ITM: holders were paid. OTM: depositors kept everything. Cancelled: under-filled, premium refunded.</span>
      </div>
      {rows.length === 0 ? (
        <div className="empty">{snap ? "No epochs yet. The first one starts once deposits and volatility history are in." : "Loading…"}</div>
      ) : (
        <div className="table-wrap">
          <table className="num">
            <thead>
              <tr>
                <th>Epoch</th>
                <th>Strike</th>
                <th>Premium</th>
                <th>Settled</th>
                <th>Outcome</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((e) => {
                const o = outcome(e);
                const spot0 = toNum(e.spotAtStart);
                const prem = toNum(e.premiumPerOption, 6);
                return (
                  <tr key={e.id}>
                    <td>#{e.id}</td>
                    <td>{fmtUsd(toNum(e.strike))}</td>
                    <td>
                      {fmtUsd(prem)} <span className="faint">{fmtPct(prem / spot0, 2)}</span>
                    </td>
                    <td>{e.settled && !e.cancelled ? fmtUsd(toNum(e.settlementPrice)) : "—"}</td>
                    <td>
                      <span className={o.cls}>{o.label}</span>
                      {e.settled && !e.cancelled && e.payoutPerOption > 0n && (
                        <span className="faint"> {fmtToken(e.payoutPerOption, 18, 4)} WETH</span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
