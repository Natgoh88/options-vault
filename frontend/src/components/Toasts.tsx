import { explorerTx } from "../chain";
import type { Toast } from "../tx";

export function Toasts({ toasts, dismiss }: { toasts: Toast[]; dismiss: (id: number) => void }) {
  if (!toasts.length) return null;
  return (
    <div className="toasts" role="status" aria-live="polite">
      {toasts.map((t) => {
        const link = t.hash ? explorerTx(t.hash) : undefined;
        return (
          <div className="toast" key={t.id}>
            {t.status === "pending" ? (
              <span className="spin" />
            ) : (
              <span className={`dot ${t.status === "success" ? "pos" : ""}`} style={{ marginTop: 7, background: t.status === "error" ? "var(--neg)" : undefined }} />
            )}
            <div>
              <div className="t">{t.title}</div>
              {t.message && <div className="m">{t.message}</div>}
              {link && (
                <a className="link" href={link} target="_blank" rel="noreferrer">
                  View transaction
                </a>
              )}
            </div>
            <button className="link" onClick={() => dismiss(t.id)} aria-label="Dismiss">
              Close
            </button>
          </div>
        );
      })}
    </div>
  );
}
