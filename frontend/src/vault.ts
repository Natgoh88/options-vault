import { useCallback, useEffect, useRef, useState } from "react";
import { encodeAbiParameters, keccak256, type Abi, type Address } from "viem";
import { deployment, hasMulticall, publicClient } from "./chain";
import { engineAbi, optionTokenAbi, resolverAbi, usdcAbi, vaultAbi } from "./abi";
import { wethAbi } from "./erc20";

export const STATES = ["Idle", "Writing", "Active", "Settling"] as const;
export type StateName = (typeof STATES)[number];

export interface Epoch {
  id: number;
  strike: bigint;
  expiry: number;
  writingEnd: number;
  spotAtStart: bigint;
  collateralLocked: bigint;
  premiumPerOption: bigint; // USDC (6 dec) per 1e18 options
  optionsSold: bigint;
  premiumCollected: bigint; // USDC (6 dec)
  settlementPrice: bigint;
  payoutPerOption: bigint; // WETH (1e18) per 1e18 options
  settled: boolean;
  cancelled: boolean; // under the minimum fill: premium refunded, nothing locked
}

export interface Greeks {
  delta: bigint;
  gamma: bigint;
  vega: bigint;
  theta: bigint;
  rho: bigint;
}

export interface UserData {
  ethBalance: bigint;
  wethBalance: bigint;
  wethAllowance: bigint;
  shares: bigint;
  maxWithdraw: bigint;
  pendingPremium: bigint;
  usdcBalance: bigint;
  usdcAllowance: bigint;
  options: Record<number, bigint>; // epoch id -> option balance (1e18 notional)
}

export interface Snapshot {
  chainTime: number;
  fetchedAtWall: number;
  state: number;
  currentEpoch: number;
  totalAssets: bigint;
  totalSupply: bigint;
  reserved: bigint;
  idleSince: number;
  idleWindow: number;
  epochDuration: number;
  writingWindow: number;
  targetDelta: bigint;
  maxDeviationBps: number;
  markupBps: number;
  minFillBps: number;
  sampleCount: number;
  spot?: bigint;
  vol?: bigint;
  epochs: Epoch[]; // newest first
  current?: Epoch;
  // Greeks are computed on-chain by PricingEngine.callGreeks
  greeks?: Greeks;
  fair?: bigint; // Black-Scholes fair value, USD (1e18) per option
  greeksStrike?: bigint;
  greeksSeconds?: number;
  indicative: boolean; // true when there is no live epoch and the numbers describe the next one
  user?: UserData;
}

type Call = { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] };

async function batch(calls: Call[]): Promise<(unknown | undefined)[]> {
  if (hasMulticall) {
    const res = await publicClient.multicall({
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      contracts: calls as any,
      allowFailure: true,
    });
    return res.map((r) => (r.status === "success" ? r.result : undefined));
  }
  return Promise.all(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    calls.map((c) => publicClient.readContract(c as any).catch(() => undefined)),
  );
}

export const optionTokenId = (strike: bigint, expiry: number): bigint =>
  BigInt(
    keccak256(
      encodeAbiParameters(
        [{ type: "uint256" }, { type: "uint256" }],
        [strike, BigInt(expiry)],
      ),
    ),
  );

const HISTORY = 12;

async function load(user: Address | undefined): Promise<Snapshot> {
  if (!deployment) throw new Error("not deployed on this network");
  const d = deployment;
  const v = { address: d.vault, abi: vaultAbi as Abi };
  const e = { address: d.engine, abi: engineAbi as Abi };

  const [block, s1] = await Promise.all([
    publicClient.getBlock({ blockTag: "latest" }),
    batch([
      { ...v, functionName: "state" },
      { ...v, functionName: "currentEpoch" },
      { ...v, functionName: "totalAssets" },
      { ...v, functionName: "totalSupply" },
      { ...v, functionName: "reservedPayout" },
      { ...v, functionName: "idleSince" },
      { ...v, functionName: "idleWindow" },
      { ...v, functionName: "epochDuration" },
      { ...v, functionName: "writingWindow" },
      { ...v, functionName: "targetDelta" },
      { ...v, functionName: "maxSpotDeviationBps" },
      { ...v, functionName: "premiumMarkupBps" },
      { ...v, functionName: "minFillBps" },
      { address: d.resolver, abi: resolverAbi as Abi, functionName: "spot" },
      { ...e, functionName: "realizedVolatility" },
      { ...e, functionName: "sampleCount" },
    ]),
  ]);

  const state = Number(s1[0] ?? 0);
  const currentEpoch = Number(s1[1] ?? 0);
  const epochDuration = Number(s1[7] ?? 0);
  const targetDelta = (s1[9] as bigint) ?? 0n;
  const spot = s1[13] as bigint | undefined;
  const vol = s1[14] as bigint | undefined;
  const chainTime = Number(block.timestamp);

  // ---- epochs (newest first) ----
  const ids: number[] = [];
  for (let i = currentEpoch; i >= Math.max(1, currentEpoch - HISTORY + 1); i--) ids.push(i);
  const epochRaw = await batch(
    ids.map((id) => ({ ...v, functionName: "epochData", args: [BigInt(id)] })),
  );
  const epochs: Epoch[] = ids.flatMap((id, i) => {
    const r = epochRaw[i] as Record<string, unknown> | undefined;
    if (!r) return [];
    return [
      {
        id,
        strike: r.strike as bigint,
        expiry: Number(r.expiry),
        writingEnd: Number(r.writingEnd),
        spotAtStart: r.spotAtStart as bigint,
        collateralLocked: r.collateralLocked as bigint,
        premiumPerOption: r.premiumPerOption as bigint,
        optionsSold: r.optionsSold as bigint,
        premiumCollected: r.premiumCollected as bigint,
        settlementPrice: r.settlementPrice as bigint,
        payoutPerOption: r.payoutPerOption as bigint,
        settled: r.settled as boolean,
        cancelled: Boolean(r.cancelled),
      },
    ];
  });
  const current = epochs[0];

  // ---- user + Greeks in parallel ----
  const live = state !== 0 && current && !current.settled;
  const userPromise = user ? loadUser(user, epochs) : Promise.resolve(undefined);
  const greeksPromise =
    spot !== undefined && vol !== undefined
      ? loadGreeks(spot, vol, live ? current : undefined, epochDuration, targetDelta, chainTime)
      : Promise.resolve(undefined);
  const [userData, g] = await Promise.all([userPromise, greeksPromise]);

  return {
    chainTime,
    fetchedAtWall: Date.now() / 1000,
    state,
    currentEpoch,
    totalAssets: (s1[2] as bigint) ?? 0n,
    totalSupply: (s1[3] as bigint) ?? 0n,
    reserved: (s1[4] as bigint) ?? 0n,
    idleSince: Number(s1[5] ?? 0),
    idleWindow: Number(s1[6] ?? 0),
    epochDuration,
    writingWindow: Number(s1[8] ?? 0),
    targetDelta,
    maxDeviationBps: Number(s1[10] ?? 0),
    markupBps: Number(s1[11] ?? 0),
    minFillBps: Number(s1[12] ?? 0),
    sampleCount: Number(s1[15] ?? 0),
    spot,
    vol,
    epochs,
    current,
    greeks: g?.greeks,
    fair: g?.fair,
    greeksStrike: g?.strike,
    greeksSeconds: g?.seconds,
    indicative: !live,
    user: userData,
  };
}

async function loadGreeks(
  spot: bigint,
  vol: bigint,
  live: Epoch | undefined,
  epochDuration: number,
  targetDelta: bigint,
  chainTime: number,
) {
  const e = { address: deployment!.engine, abi: engineAbi as Abi };
  let strike: bigint | undefined;
  let seconds: number;
  if (live) {
    strike = live.strike;
    seconds = Math.max(1, live.expiry - chainTime);
  } else {
    seconds = epochDuration;
    [strike] = (await batch([
      { ...e, functionName: "strikeForDelta", args: [spot, vol, BigInt(seconds), targetDelta] },
    ])) as (bigint | undefined)[];
  }
  if (strike === undefined) return undefined;
  const [greeks, fair] = await batch([
    { ...e, functionName: "callGreeks", args: [spot, strike, vol, BigInt(seconds)] },
    { ...e, functionName: "callPrice", args: [spot, strike, vol, BigInt(seconds)] },
  ]);
  return { greeks: greeks as Greeks | undefined, fair: fair as bigint | undefined, strike, seconds };
}

async function loadUser(user: Address, epochs: Epoch[]): Promise<UserData> {
  const d = deployment!;
  const v = { address: d.vault, abi: vaultAbi as Abi };
  const optCalls: Call[] = epochs.map((ep) => ({
    address: d.optionToken,
    abi: optionTokenAbi as Abi,
    functionName: "balanceOf",
    args: [user, optionTokenId(ep.strike, ep.expiry)],
  }));
  const [eth, r, opts] = await Promise.all([
    publicClient.getBalance({ address: user }),
    batch([
      { address: d.weth, abi: wethAbi as Abi, functionName: "balanceOf", args: [user] },
      { address: d.weth, abi: wethAbi as Abi, functionName: "allowance", args: [user, d.vault] },
      { ...v, functionName: "balanceOf", args: [user] },
      { ...v, functionName: "maxWithdraw", args: [user] },
      { ...v, functionName: "pendingPremium", args: [user] },
      { address: d.usdc, abi: usdcAbi as Abi, functionName: "balanceOf", args: [user] },
      { address: d.usdc, abi: usdcAbi as Abi, functionName: "allowance", args: [user, d.vault] },
    ]),
    batch(optCalls),
  ]);
  const options: Record<number, bigint> = {};
  epochs.forEach((ep, i) => {
    const b = opts[i] as bigint | undefined;
    if (b && b > 0n) options[ep.id] = b;
  });
  return {
    ethBalance: eth,
    wethBalance: (r[0] as bigint) ?? 0n,
    wethAllowance: (r[1] as bigint) ?? 0n,
    shares: (r[2] as bigint) ?? 0n,
    maxWithdraw: (r[3] as bigint) ?? 0n,
    pendingPremium: (r[4] as bigint) ?? 0n,
    usdcBalance: (r[5] as bigint) ?? 0n,
    usdcAllowance: (r[6] as bigint) ?? 0n,
    options,
  };
}

export function useVault(user: Address | undefined, intervalMs = 10_000) {
  const [snap, setSnap] = useState<Snapshot>();
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(true);
  const seq = useRef(0);

  const refresh = useCallback(async () => {
    const id = ++seq.current;
    try {
      const s = await load(user);
      if (id === seq.current) {
        setSnap(s);
        setError(undefined);
      }
    } catch (e) {
      if (id === seq.current) setError((e as Error).message);
    } finally {
      if (id === seq.current) setLoading(false);
    }
  }, [user]);

  useEffect(() => {
    setLoading(true);
    refresh();
    const t = setInterval(refresh, intervalMs);
    return () => clearInterval(t);
  }, [refresh, intervalMs]);

  return { snap, error, loading, refresh };
}

/** Chain-time clock that ticks every second, anchored to the latest block timestamp. */
export function useChainNow(snap: Snapshot | undefined): number {
  const [, setTick] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setTick((x) => x + 1), 1000);
    return () => clearInterval(t);
  }, []);
  if (!snap) return Date.now() / 1000;
  return snap.chainTime + (Date.now() / 1000 - snap.fetchedAtWall);
}
