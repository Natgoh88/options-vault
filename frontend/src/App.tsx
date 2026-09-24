import { useCallback, useState } from "react";
import { chain, deployment } from "./chain";
import { useWallet } from "./wallet";
import { useChainNow, useVault } from "./vault";
import { useTxs } from "./tx";
import { Header } from "./components/Header";
import { Stats } from "./components/Stats";
import { EpochPanel } from "./components/EpochPanel";
import { PayoffChart } from "./components/PayoffChart";
import { GreeksPanel } from "./components/GreeksPanel";
import { History } from "./components/History";
import { ActionCard } from "./components/ActionCard";
import { Footer } from "./components/Footer";
import { Toasts } from "./components/Toasts";

export default function App() {
  const wallet = useWallet();
  const { snap, error, refresh } = useVault(wallet.address);
  const now = useChainNow(snap);
  const [notice, setNotice] = useState<string>();

  const settled = useCallback(() => {
    refresh();
    // a second read shortly after catches state that the RPC node has not indexed yet
    setTimeout(refresh, 2500);
  }, [refresh]);
  const { toasts, run, dismiss } = useTxs(wallet.client, settled);

  const onError = useCallback((m: string) => {
    setNotice(m);
    setTimeout(() => setNotice(undefined), 6000);
  }, []);

  if (!deployment) {
    return (
      <>
        <Header wallet={wallet} onError={onError} />
        <main className="shell">
          <div className="fullpage">
            <div>
              <h1>Not deployed on {chain.name}</h1>
              <p>Run the deploy script, then sync the deployment into the frontend.</p>
              <p className="mono">forge script script/Deploy.s.sol --broadcast &amp;&amp; npm run sync</p>
            </div>
          </div>
        </main>
      </>
    );
  }

  return (
    <>
      <Header wallet={wallet} onError={onError} />
      <main>
        <div className="shell">
          <div className="intro">
            <div>
              <h1>Covered calls, priced and settled on-chain.</h1>
              <p>
                Deposit WETH. Each epoch the vault sells calls against it at a strike chosen by an on-chain Black-Scholes engine, and
                pays you the premium in USDC.
              </p>
            </div>
          </div>

          {error && !snap && (
            <div className="panel" style={{ marginBottom: 24 }}>
              <div className="empty">Could not read the vault: {error}</div>
            </div>
          )}

          <Stats snap={snap} now={now} />

          <div className="grid">
            <div className="stack">
              <EpochPanel snap={snap} now={now} />
              <PayoffChart snap={snap} />
              <GreeksPanel snap={snap} />
              <History snap={snap} />
            </div>
            <aside className="aside">
              <ActionCard snap={snap} wallet={wallet} now={now} run={run} onError={onError} />
            </aside>
          </div>
        </div>
      </main>
      <Footer />
      <Toasts
        toasts={notice ? [...toasts, { id: -1, title: notice, status: "error" }] : toasts}
        dismiss={(id) => (id === -1 ? setNotice(undefined) : dismiss(id))}
      />
    </>
  );
}
