import { createPublicClient, defineChain, http, type Address, type PublicClient } from "viem";
import { arbitrumSepolia } from "viem/chains";
import prod from "./deployments.json";

// The local anvil deployment is gitignored and only exists after `npm run sync` on a dev machine.
// A glob import tolerates the file being absent (fresh clones, Vercel), and it is only read in
// dev builds so throwaway local addresses can never ship to production.
const localFiles = import.meta.env.DEV
  ? import.meta.glob<Record<string, unknown>>("./deployments.local.json", { eager: true, import: "default" })
  : {};
const local = Object.values(localFiles)[0] ?? {};

const LOCAL_ID = 31337;
const wanted = Number(import.meta.env.VITE_CHAIN_ID ?? arbitrumSepolia.id);

export const localChain = defineChain({
  id: LOCAL_ID,
  name: "Local (anvil)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [import.meta.env.VITE_RPC_URL ?? "http://127.0.0.1:8545"] } },
});

export const chain = wanted === LOCAL_ID ? localChain : arbitrumSepolia;
export const isLocal = chain.id === LOCAL_ID;

export const rpcUrl: string =
  import.meta.env.VITE_RPC_URL ?? (isLocal ? "http://127.0.0.1:8545" : arbitrumSepolia.rpcUrls.default.http[0]);

export interface Deployment {
  chainId: number;
  vault: Address;
  engine: Address;
  resolver: Address;
  optionToken: Address;
  keeper: Address;
  weth: Address;
  usdc: Address;
  feed: Address;
  epochDuration: number;
  writingWindow: number;
  idleWindow: number;
  targetDelta: number;
  deployBlock: number;
}

const deployments = { ...prod, ...local } as unknown as Record<string, Deployment | undefined>;
export const deployment: Deployment | undefined = deployments[String(chain.id)];

export const publicClient: PublicClient = createPublicClient({
  chain,
  transport: http(rpcUrl),
});

export const hasMulticall = Boolean(chain.contracts && "multicall3" in chain.contracts);

export const explorer: string | undefined = chain.blockExplorers?.default.url;

export const explorerAddress = (a: string) => (explorer ? `${explorer}/address/${a}` : undefined);
export const explorerTx = (h: string) => (explorer ? `${explorer}/tx/${h}` : undefined);
