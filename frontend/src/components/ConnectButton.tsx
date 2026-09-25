import { useEffect, useRef, useState } from "react";
import type { Wallet, WalletOption } from "../wallet";

/** Connect button. With more than one wallet installed it opens a picker instead of guessing. */
export function ConnectButton({
  wallet,
  onError,
  large = false,
}: {
  wallet: Wallet;
  onError: (m: string) => void;
  large?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent | KeyboardEvent) => {
      if (e instanceof KeyboardEvent ? e.key === "Escape" : !ref.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", close);
    return () => {
      document.removeEventListener("mousedown", close);
      document.removeEventListener("keydown", close);
    };
  }, [open]);

  const go = (o?: WalletOption) => {
    setOpen(false);
    wallet.connect(o).catch((e) => onError((e as Error).message));
  };

  const cls = `btn primary${large ? " lg" : ""}`;
  if (wallet.options.length <= 1) {
    return (
      <button className={cls} onClick={() => go(wallet.options[0])}>
        Connect wallet
      </button>
    );
  }

  return (
    <div className="menu-wrap" ref={ref} style={large ? { width: "100%" } : undefined}>
      <button className={cls} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        Connect wallet
      </button>
      {open && (
        <div className="menu" role="menu">
          {wallet.options.map((o) => (
            <button key={o.uuid} role="menuitem" className="menu-item" onClick={() => go(o)}>
              <img src={o.icon} alt="" width={20} height={20} />
              {o.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
