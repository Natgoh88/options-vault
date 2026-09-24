import { formatUnits, parseUnits } from "viem";

const MINUS = "−";

/** bigint (with `decimals`) to a JS number. Fine for display, never for accounting. */
export const toNum = (v: bigint | undefined, decimals = 18): number =>
  v === undefined ? NaN : Number(formatUnits(v, decimals));

export function fmtNum(n: number, dp = 2): string {
  if (!Number.isFinite(n)) return "-";
  return n.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

/** "$1,234.50", with a true minus sign in front for negatives. */
export function fmtUsd(n: number, dp = 2): string {
  if (!Number.isFinite(n)) return "-";
  return (n < 0 ? MINUS : "") + "$" + fmtNum(Math.abs(n), dp);
}

/** Token amount with adaptive precision: small values keep significant digits. */
export function fmtToken(v: bigint | undefined, decimals = 18, maxDp = 4): string {
  if (v === undefined) return "-";
  const n = toNum(v, decimals);
  if (n === 0) return "0";
  if (Math.abs(n) < 10 ** -maxDp) return "<" + (10 ** -maxDp).toFixed(maxDp);
  return fmtNum(n, maxDp).replace(/\.?0+$/, "");
}

export function fmtPct(n: number, dp = 2): string {
  if (!Number.isFinite(n)) return "-";
  return fmtNum(n * 100, dp) + "%";
}

export function fmtDuration(totalSeconds: number): string {
  if (!Number.isFinite(totalSeconds)) return "-";
  const s = Math.max(0, Math.floor(totalSeconds));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m.toString().padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${sec.toString().padStart(2, "0")}s`;
  return `${sec}s`;
}

export const shortAddr = (a?: string): string => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

export function fmtDateTime(ts: number): string {
  return new Date(ts * 1000).toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
}

/** Parse a user-typed decimal string; returns undefined if empty or invalid. */
export function parseAmount(s: string, decimals: number): bigint | undefined {
  const t = s.trim();
  if (!t || !/^\d*\.?\d*$/.test(t) || t === ".") return undefined;
  try {
    return parseUnits(t, decimals);
  } catch {
    return undefined;
  }
}
