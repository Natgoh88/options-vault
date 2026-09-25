import { chain } from "../chain";
import { shortAddr } from "../format";
import type { Wallet } from "../wallet";
import { ConnectButton } from "./ConnectButton";

export function Mark({ size = 20 }: { size?: number }) {
  // a call-option payoff: flat, then a hockey-stick up and to the right
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <rect x="0.75" y="0.75" width="30.5" height="30.5" rx="7" stroke="#2a2a31" strokeWidth="1.5" />
      <path d="M7 21.5H16L25 9.5" stroke="#f3f3f4" strokeWidth="2.2" strokeLinecap="square" />
    </svg>
  );
}

export function Header({ wallet, onError }: { wallet: Wallet; onError: (m: string) => void }) {
  return (
    <header className="header">
      <div className="shell">
        <div className="brand">
          <Mark size={24} />
          <span>Options Vault</span>
        </div>
        <div className="header-right">
          <span className="chip net">
            <span className="dot pos" />
            {chain.name}
          </span>
          {!wallet.address ? (
            <ConnectButton wallet={wallet} onError={onError} />
          ) : wallet.wrongNetwork ? (
            <button className="btn primary" onClick={() => wallet.switchNetwork().catch((e) => onError((e as Error).message))}>
              Switch to {chain.name}
            </button>
          ) : (
            <button className="btn" onClick={wallet.disconnect} title={`${wallet.walletName ?? "Wallet"} · click to disconnect`}>
              <span className="mono">{shortAddr(wallet.address)}</span>
            </button>
          )}
        </div>
      </div>
    </header>
  );
}
