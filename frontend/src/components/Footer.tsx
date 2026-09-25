import { chain, deployment, explorerAddress } from "../chain";
import { shortAddr } from "../format";

const REPO = "https://github.com/Natgoh88/options-vault";

export function Footer() {
  const d = deployment;
  const rows: [string, string | undefined][] = d
    ? [
        ["Vault", d.vault],
        ["Pricing engine", d.engine],
        ["Settlement resolver", d.resolver],
        ["Option token", d.optionToken],
        ["Keeper", d.keeper],
        ["Chainlink ETH / USD", d.feed],
      ]
    : [];

  return (
    <footer className="footer">
      <div className="shell">
        <div>
          <p>
            <strong style={{ color: "var(--text-2)", fontWeight: 500 }}>Testnet only. Not a financial product.</strong> This is a
            research prototype running on {chain.name}. It has been reviewed by its authors and tested extensively, but it has not
            been audited by a third party and holds no real value.
          </p>
          <p>
            Options are priced on-chain with Black-Scholes from a volatility estimate the contract maintains itself, and settle
            against the Chainlink round in effect at expiry. Realized volatility can differ from what the market implies, so the
            vault can lose money.
          </p>
          <div className="links">
            <a href={REPO} target="_blank" rel="noreferrer">
              Source
            </a>
            <a href={`${REPO}/blob/main/docs/security-report.md`} target="_blank" rel="noreferrer">
              Security report
            </a>
            <a href={`${REPO}/blob/main/docs/post-p5-audit.md`} target="_blank" rel="noreferrer">
              Design audits
            </a>
          </div>
        </div>
        {rows.length > 0 && (
          <div className="addrs num">
            {rows.map(([name, addr]) => (
              <FooterRow key={name} name={name} addr={addr!} />
            ))}
          </div>
        )}
      </div>
    </footer>
  );
}

function FooterRow({ name, addr }: { name: string; addr: string }) {
  const href = explorerAddress(addr);
  return (
    <>
      <span>{name}</span>
      {href ? (
        <a className="mono" href={href} target="_blank" rel="noreferrer">
          {shortAddr(addr)}
        </a>
      ) : (
        <span className="mono">{shortAddr(addr)}</span>
      )}
    </>
  );
}
