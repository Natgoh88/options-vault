import { useMemo, useState } from "react";
import { deployment } from "../chain";
import { fmtDuration, fmtNum, fmtToken, fmtUsd, parseAmount, toNum } from "../format";
import { usdcAbi, vaultAbi } from "../abi";
import { wethAbi } from "../erc20";
import { writeTx } from "../tx";
import type { Wallet } from "../wallet";
import { ConnectButton } from "./ConnectButton";
import type { Snapshot } from "../vault";
import type { WalletClient, Hash } from "viem";

type Run = (title: string, send: (c: WalletClient) => Promise<Hash>) => Promise<boolean>;
type Tab = "deposit" | "withdraw" | "options";

const OFFSET = 1000n; // ERC-4626 virtual-share offset (10 ** 3), matches the contract

const sharesFor = (assets: bigint, s: Snapshot) => (assets * (s.totalSupply + OFFSET)) / (s.totalAssets + 1n);
const assetsFor = (shares: bigint, s: Snapshot) => (shares * (s.totalAssets + 1n)) / (s.totalSupply + OFFSET);

interface Props {
  snap?: Snapshot;
  wallet: Wallet;
  now: number;
  run: Run;
  onError: (m: string) => void;
}

export function ActionCard({ snap, wallet, now, run, onError }: Props) {
  const [tab, setTab] = useState<Tab>("deposit");
  return (
    <>
      <section className="panel">
        <div className="tabs" role="tablist">
          {(["deposit", "withdraw", "options"] as Tab[]).map((t) => (
            <button key={t} role="tab" aria-selected={tab === t} className={`tab ${tab === t ? "on" : ""}`} onClick={() => setTab(t)}>
              {t === "deposit" ? "Deposit" : t === "withdraw" ? "Withdraw" : "Options"}
            </button>
          ))}
        </div>
        <div className="panel-b">
          {tab === "deposit" && <Deposit {...{ snap, wallet, now, run, onError }} />}
          {tab === "withdraw" && <Withdraw {...{ snap, wallet, now, run, onError }} />}
          {tab === "options" && <Options {...{ snap, wallet, now, run, onError }} />}
        </div>
      </section>
      <Claim {...{ snap, wallet, now, run, onError }} />
    </>
  );
}

/* ---------------------------------------------------------------- shared bits */

function Gate({ wallet, onError, children }: { wallet: Wallet; onError: (m: string) => void; children: React.ReactNode }) {
  if (!wallet.address) {
    return <ConnectButton wallet={wallet} onError={onError} large />;
  }
  if (wallet.wrongNetwork) {
    return (
      <button className="btn primary lg" onClick={() => wallet.switchNetwork().catch((e) => onError((e as Error).message))}>
        Switch network
      </button>
    );
  }
  return <>{children}</>;
}

function AmountField(props: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  unit: string;
  balanceLabel: string;
  balance: string;
  onMax?: () => void;
  disabled?: boolean;
}) {
  return (
    <div className="field">
      <div className="field-top">
        <span>{props.label}</span>
        <span className="num">
          {props.balanceLabel} {props.balance}
          {props.onMax && !props.disabled && (
            <>
              {" "}
              <button className="link" onClick={props.onMax}>
                Max
              </button>
            </>
          )}
        </span>
      </div>
      <div className="field-row">
        <input
          inputMode="decimal"
          autoComplete="off"
          placeholder="0.0"
          aria-label={props.label}
          value={props.value}
          disabled={props.disabled}
          onChange={(e) => props.onChange(e.target.value.replace(",", "."))}
        />
        <span className="unit">{props.unit}</span>
      </div>
    </div>
  );
}

const sanitize = (s: string, decimals: number) => {
  const [i, f] = s.split(".");
  return f === undefined ? i : `${i}.${f.slice(0, decimals)}`;
};

/* ---------------------------------------------------------------- deposit */

function Deposit({ snap, wallet, run, onError, now }: Props) {
  const d = deployment!;
  const [text, setText] = useState("");
  const [wrapText, setWrapText] = useState("");
  const [wrapOpen, setWrapOpen] = useState(false);

  const u = snap?.user;
  const amt = parseAmount(text, 18);
  const open = snap?.state === 0;
  const insufficient = amt !== undefined && u !== undefined && amt > u.wethBalance;
  const needsApprove = amt !== undefined && u !== undefined && u.wethAllowance < amt;
  const shares = amt !== undefined && snap ? sharesFor(amt, snap) : undefined;
  const sharePct =
    shares !== undefined && snap ? Number((shares * 10000n) / (snap.totalSupply + shares + 1n)) / 100 : undefined;

  const act = async () => {
    if (!amt || !wallet.address) return;
    if (needsApprove) {
      await run("Approve WETH", (c) => writeTx(c, d.weth, wethAbi, "approve", [d.vault, amt]));
      return;
    }
    const ok = await run("Deposit WETH", (c) => writeTx(c, d.vault, vaultAbi, "deposit", [amt, wallet.address]));
    if (ok) setText("");
  };

  const wrapAmt = parseAmount(wrapText, 18);
  const wrap = async () => {
    if (!wrapAmt) return;
    const ok = await run("Wrap ETH", (c) => writeTx(c, d.weth, wethAbi, "deposit", [], wrapAmt));
    if (ok) {
      setWrapText("");
      setWrapOpen(false);
    }
  };

  let label = "Enter an amount";
  let disabled = true;
  if (!open) label = "Deposits closed";
  else if (insufficient) label = "Insufficient WETH";
  else if (amt && amt > 0n) {
    label = needsApprove ? "Approve WETH" : "Deposit";
    disabled = false;
  }

  return (
    <>
      <AmountField
        label="Deposit"
        value={text}
        onChange={(v) => setText(sanitize(v, 18))}
        unit="WETH"
        balanceLabel="Balance"
        balance={u ? fmtToken(u.wethBalance, 18, 4) : "—"}
        onMax={u ? () => setText(toDecimal(u.wethBalance)) : undefined}
        disabled={!open}
      />

      <div className="rows num">
        <div>
          <span>You receive</span>
          <span>{shares !== undefined ? `${fmtNum(toNum(shares, 18), 4)} ovWETH` : "—"}</span>
        </div>
        <div>
          <span>Share of vault</span>
          <span>{sharePct !== undefined ? `${fmtNum(sharePct, 2)}%` : "—"}</span>
        </div>
        <div>
          <span>Earns</span>
          <span>USDC premium each epoch</span>
        </div>
      </div>

      <Gate wallet={wallet} onError={onError}>
        <button className="btn primary lg" disabled={disabled} onClick={act}>
          {label}
        </button>
      </Gate>

      {snap && !open && (
        <p className="callout">
          <b>Collateral is locked.</b> Deposits and withdrawals open again after this epoch settles
          {snap.current && snap.state === 2 && now < snap.current.expiry ? `, in about ${fmtDuration(snap.current.expiry - now)}` : ""}. That is what
          guarantees every sold option is fully backed.
        </p>
      )}

      {wallet.address && !wallet.wrongNetwork && (
        <div style={{ marginTop: 16 }}>
          {!wrapOpen ? (
            <button className="link" onClick={() => setWrapOpen(true)}>
              Need WETH? Wrap ETH
            </button>
          ) : (
            <div className="field" style={{ padding: "10px 12px" }}>
              <div className="field-row" style={{ marginTop: 0 }}>
                <input
                  style={{ fontSize: 16 }}
                  inputMode="decimal"
                  placeholder="ETH to wrap"
                  aria-label="ETH to wrap"
                  value={wrapText}
                  onChange={(e) => setWrapText(sanitize(e.target.value.replace(",", "."), 18))}
                />
                <button className="btn sm" disabled={!wrapAmt || (u !== undefined && wrapAmt > u.ethBalance)} onClick={wrap}>
                  Wrap
                </button>
              </div>
              <div className="field-top" style={{ marginTop: 6 }}>
                <span className="num">ETH balance {u ? fmtToken(u.ethBalance, 18, 4) : "—"}</span>
              </div>
            </div>
          )}
        </div>
      )}
    </>
  );
}

/* ---------------------------------------------------------------- withdraw */

function Withdraw({ snap, wallet, run, onError, now }: Props) {
  const d = deployment!;
  const [text, setText] = useState("");
  const u = snap?.user;
  const open = snap?.state === 0;
  const amt = parseAmount(text, 18);
  const position = u && snap ? assetsFor(u.shares, snap) : undefined;
  const max = u?.maxWithdraw ?? 0n;
  const insufficient = amt !== undefined && amt > max;

  const act = async () => {
    if (!amt || !wallet.address) return;
    const ok = await run("Withdraw WETH", (c) =>
      writeTx(c, d.vault, vaultAbi, "withdraw", [amt, wallet.address, wallet.address]),
    );
    if (ok) setText("");
  };

  let label = "Enter an amount";
  let disabled = true;
  if (!open) label = "Withdrawals closed";
  else if (insufficient) label = "Exceeds your position";
  else if (amt && amt > 0n) {
    label = "Withdraw";
    disabled = false;
  }

  return (
    <>
      <AmountField
        label="Withdraw"
        value={text}
        onChange={(v) => setText(sanitize(v, 18))}
        unit="WETH"
        balanceLabel="Position"
        balance={position !== undefined ? fmtToken(position, 18, 4) : "—"}
        onMax={u ? () => setText(toDecimal(max)) : undefined}
        disabled={!open}
      />
      <div className="rows num">
        <div>
          <span>Shares held</span>
          <span>{u ? `${fmtNum(toNum(u.shares, 18), 4)} ovWETH` : "—"}</span>
        </div>
        <div>
          <span>Value</span>
          <span>
            {position !== undefined && snap?.spot !== undefined ? fmtUsd(toNum(position) * toNum(snap.spot)) : "—"}
          </span>
        </div>
      </div>
      <Gate wallet={wallet} onError={onError}>
        <button className="btn primary lg" disabled={disabled} onClick={act}>
          {label}
        </button>
      </Gate>
      {snap && !open && (
        <p className="callout">
          <b>Your WETH is collateral for options that have been sold.</b> It can be withdrawn once the epoch settles
          {snap.current && snap.state === 2 && now < snap.current.expiry ? `, in about ${fmtDuration(snap.current.expiry - now)}` : ""}. Premium
          already earned can be claimed at any time.
        </p>
      )}
    </>
  );
}

/* ---------------------------------------------------------------- options */

function Options({ snap, wallet, run, onError, now }: Props) {
  const d = deployment!;
  const [text, setText] = useState("");
  const u = snap?.user;
  const cur = snap?.current;
  const selling = snap?.state === 1 && cur && now <= cur.writingEnd;
  const amt = parseAmount(text, 18);

  const remaining = selling ? cur!.collateralLocked - cur!.optionsSold : 0n;
  // premium rounds up in the contract; mirror that so the approval always covers it
  const cost = amt !== undefined && cur ? (amt * cur.premiumPerOption + 10n ** 18n - 1n) / 10n ** 18n : undefined;
  const insufficient = cost !== undefined && u !== undefined && cost > u.usdcBalance;
  const tooMany = amt !== undefined && amt > remaining;
  const needsApprove = cost !== undefined && u !== undefined && u.usdcAllowance < cost;

  const buy = async () => {
    if (!amt || !cost) return;
    if (needsApprove) {
      await run("Approve USDC", (c) => writeTx(c, d.usdc, usdcAbi, "approve", [d.vault, cost]));
      return;
    }
    const ok = await run("Buy options", (c) => writeTx(c, d.vault, vaultAbi, "buyOptions", [amt]));
    if (ok) setText("");
  };

  let label = "Enter an amount";
  let disabled = true;
  if (!selling) label = "Not on sale";
  else if (tooMany) label = "Exceeds available";
  else if (insufficient) label = "Insufficient USDC";
  else if (amt && amt > 0n) {
    label = needsApprove ? "Approve USDC" : "Buy options";
    disabled = false;
  }

  const positions = useMemo(
    () => (snap && u ? snap.epochs.filter((e) => (u.options[e.id] ?? 0n) > 0n) : []),
    [snap, u],
  );

  return (
    <>
      <AmountField
        label="Options to buy"
        value={text}
        onChange={(v) => setText(sanitize(v, 18))}
        unit="WETH"
        balanceLabel="Available"
        balance={selling ? fmtToken(remaining, 18, 4) : "—"}
        onMax={selling ? () => setText(toDecimal(remaining)) : undefined}
        disabled={!selling}
      />
      <div className="rows num">
        <div>
          <span>Strike</span>
          <span>{cur && selling ? fmtUsd(toNum(cur.strike)) : "—"}</span>
        </div>
        <div>
          <span>Premium per WETH</span>
          <span>{cur && selling ? fmtUsd(toNum(cur.premiumPerOption, 6)) : "—"}</span>
        </div>
        <div>
          <span>Total cost</span>
          <span>{cost !== undefined ? `${fmtNum(toNum(cost, 6), 2)} USDC` : "—"}</span>
        </div>
        <div>
          <span>USDC balance</span>
          <span>{u ? fmtNum(toNum(u.usdcBalance, 6), 2) : "—"}</span>
        </div>
      </div>

      <Gate wallet={wallet} onError={onError}>
        <button className="btn primary lg" disabled={disabled} onClick={buy}>
          {label}
        </button>
      </Gate>

      {snap && !selling && (
        <p className="callout">
          Options are sold at a fixed strike and premium during the writing window at the start of each epoch. They pay out in WETH,
          {" "}(price {"−"} strike) / price, if ETH finishes above the strike.
        </p>
      )}

      {wallet.address && !wallet.wrongNetwork && (
        <div style={{ marginTop: 16 }}>
          <button
            className="link"
            onClick={() => run("Get test USDC", (c) => writeTx(c, d.usdc, usdcAbi, "faucet"))}
          >
            Get 10,000 test USDC
          </button>
        </div>
      )}

      {positions.length > 0 && snap && u && (
        <div className="positions">
          <div className="label" style={{ marginBottom: 6 }}>
            Your options
          </div>
          {positions.map((e) => {
            const bal = u.options[e.id];
            // cancelled epochs refund the USDC premium (6 dec); settled ones pay WETH (18 dec)
            const refund = e.cancelled ? (bal * e.premiumPerOption) / 10n ** 18n : 0n;
            const payout = e.settled && !e.cancelled ? (bal * e.payoutPerOption) / 10n ** 18n : 0n;
            const status = e.cancelled
              ? `cancelled, refund ${fmtNum(toNum(refund, 6), 2)} USDC`
              : e.settled
                ? payout > 0n
                  ? `pays ${fmtToken(payout, 18, 6)} WETH`
                  : "expired worthless"
                : "awaiting settlement";
            return (
              <div className="pos-row num" key={e.id}>
                <div>
                  <div>
                    {fmtToken(bal, 18, 4)} WETH {"·"} strike {fmtUsd(toNum(e.strike), 0)}
                  </div>
                  <div className="faint" style={{ fontSize: 12 }}>
                    Epoch #{e.id} {"·"} {status}
                  </div>
                </div>
                {e.settled && (
                  <button
                    className="btn sm"
                    onClick={() => run(e.cancelled ? `Refund epoch #${e.id}` : `Redeem epoch #${e.id}`, (c) => writeTx(c, d.vault, vaultAbi, "redeemOptions", [BigInt(e.id), bal]))}
                  >
                    {e.cancelled ? "Refund" : payout > 0n ? "Redeem" : "Clear"}
                  </button>
                )}
              </div>
            );
          })}
        </div>
      )}
    </>
  );
}

/* ---------------------------------------------------------------- premium claim */

function Claim({ snap, wallet, run }: Props) {
  const d = deployment!;
  const p = snap?.user?.pendingPremium ?? 0n;
  if (!wallet.address || wallet.wrongNetwork || !snap?.user || (p === 0n && snap.user.shares === 0n)) return null;
  return (
    <section className="panel claim">
      <div>
        <div className="label">Claimable premium</div>
        <div className="v num">{fmtNum(toNum(p, 6), 2)} USDC</div>
      </div>
      <button className="btn" disabled={p === 0n} onClick={() => run("Claim premium", (c) => writeTx(c, d.vault, vaultAbi, "claimPremium"))}>
        Claim
      </button>
    </section>
  );
}

function toDecimal(v: bigint): string {
  const s = v.toString().padStart(19, "0");
  const i = s.slice(0, -18);
  const f = s.slice(-18).replace(/0+$/, "");
  return f ? `${i}.${f}` : i;
}
