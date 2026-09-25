import { useCallback, useEffect, useMemo, useState } from "react";
import {
  createWalletClient,
  custom,
  http,
  numberToHex,
  type Address,
  type EIP1193Provider,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chain, isLocal, rpcUrl } from "./chain";

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

// Local development only: sign with a throwaway anvil key so the UI can be driven without a
// browser extension. Refused on any non-local chain, so it can never touch a real network.
// `import.meta.env.DEV` is a compile-time false in production builds, so the key is dropped from
// the bundle entirely rather than merely ignored at runtime.
const devKey =
  import.meta.env.DEV && isLocal ? (import.meta.env.VITE_DEV_PRIVATE_KEY as `0x${string}` | undefined) : undefined;

/** An injected wallet announced via EIP-6963 (multi-wallet discovery). */
export interface WalletOption {
  uuid: string;
  name: string;
  icon: string; // data: URI supplied by the wallet
  rdns: string;
  provider: EIP1193Provider;
}

const STORAGE_KEY = "ov.wallet.rdns";
const remember = (rdns: string | undefined) => {
  try {
    if (rdns) localStorage.setItem(STORAGE_KEY, rdns);
    else localStorage.removeItem(STORAGE_KEY);
  } catch {
    /* storage unavailable: private mode etc. */
  }
};
const recall = (): string | undefined => {
  try {
    return localStorage.getItem(STORAGE_KEY) ?? undefined;
  } catch {
    return undefined;
  }
};

/** EIP-6963: every installed wallet announces itself, instead of fighting over window.ethereum. */
function useWalletOptions(): WalletOption[] {
  const [options, setOptions] = useState<WalletOption[]>([]);
  useEffect(() => {
    const onAnnounce = (ev: Event) => {
      const { info, provider } = (ev as CustomEvent).detail ?? {};
      if (!info?.uuid || !provider) return;
      setOptions((prev) =>
        prev.some((o) => o.uuid === info.uuid)
          ? prev
          : [...prev, { uuid: info.uuid, name: info.name, icon: info.icon, rdns: info.rdns, provider }],
      );
    };
    window.addEventListener("eip6963:announceProvider", onAnnounce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    return () => window.removeEventListener("eip6963:announceProvider", onAnnounce);
  }, []);
  return options;
}

export interface Wallet {
  address?: Address;
  /** Discovered wallets; more than one means the UI should let the user pick. */
  options: WalletOption[];
  walletName?: string;
  chainId?: number;
  wrongNetwork: boolean;
  hasProvider: boolean;
  connect: (option?: WalletOption) => Promise<void>;
  disconnect: () => void;
  switchNetwork: () => Promise<void>;
  client?: WalletClient;
}

export function useWallet(): Wallet {
  const options = useWalletOptions();
  const [chosen, setChosen] = useState<WalletOption | undefined>();
  // Prefer the wallet the user picked, then the one used last time, then a lone announced wallet,
  // then the legacy injected provider.
  const remembered = options.find((o) => o.rdns === recall());
  const active = chosen ?? remembered ?? (options.length === 1 ? options[0] : undefined);
  const eth: EIP1193Provider | undefined =
    active?.provider ?? (typeof window !== "undefined" ? window.ethereum : undefined);
  const devAccount = useMemo(() => (devKey ? privateKeyToAccount(devKey) : undefined), []);

  const [address, setAddress] = useState<Address | undefined>(devAccount?.address);
  const [chainId, setChainId] = useState<number | undefined>(devAccount ? chain.id : undefined);
  const [disconnected, setDisconnected] = useState(false);

  useEffect(() => {
    if (devAccount || !eth) return;
    let alive = true;
    (async () => {
      // silently restore a previously authorised session; never prompts
      const accounts = (await eth.request({ method: "eth_accounts" })) as Address[];
      const id = (await eth.request({ method: "eth_chainId" })) as string;
      if (!alive) return;
      setAddress(accounts[0]);
      setChainId(Number(id));
    })().catch(() => {});

    const onAccounts = (accounts: unknown) => setAddress((accounts as Address[])[0]);
    const onChain = (id: unknown) => setChainId(Number(id as string));
    eth.on?.("accountsChanged", onAccounts);
    eth.on?.("chainChanged", onChain);
    return () => {
      alive = false;
      eth.removeListener?.("accountsChanged", onAccounts);
      eth.removeListener?.("chainChanged", onChain);
    };
  }, [eth, devAccount]);

  const connect = useCallback(
    async (option?: WalletOption) => {
      if (devAccount) return;
      const target = option?.provider ?? eth;
      if (!target) throw new Error("No wallet found. Install MetaMask, Rabby or Coinbase Wallet.");
      const accounts = (await target.request({ method: "eth_requestAccounts" })) as Address[];
      const id = (await target.request({ method: "eth_chainId" })) as string;
      if (option) {
        setChosen(option);
        remember(option.rdns);
      }
      setDisconnected(false);
      setAddress(accounts[0]);
      setChainId(Number(id));
    },
    [eth, devAccount],
  );

  const switchNetwork = useCallback(async () => {
    if (!eth) return;
    const chainIdHex = numberToHex(chain.id);
    try {
      await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: chainIdHex }] });
    } catch (e) {
      // 4902: chain not added to the wallet yet
      if ((e as { code?: number }).code === 4902) {
        await eth.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: chainIdHex,
              chainName: chain.name,
              nativeCurrency: chain.nativeCurrency,
              rpcUrls: [rpcUrl],
              blockExplorerUrls: chain.blockExplorers ? [chain.blockExplorers.default.url] : undefined,
            },
          ],
        });
      } else {
        throw e;
      }
    }
  }, [eth]);

  // EIP-1193 has no "disconnect"; this only forgets the account inside the app.
  const disconnect = useCallback(() => {
    setDisconnected(true);
    remember(undefined);
  }, []);

  const connected = disconnected ? undefined : address;

  const client = useMemo<WalletClient | undefined>(() => {
    if (!connected) return undefined;
    if (devAccount) return createWalletClient({ account: devAccount, chain, transport: http(rpcUrl) });
    if (!eth) return undefined;
    return createWalletClient({ account: connected, chain, transport: custom(eth) });
  }, [connected, eth, devAccount]);

  return {
    address: connected,
    options,
    walletName: devAccount ? "Dev signer" : active?.name,
    chainId,
    wrongNetwork: connected !== undefined && chainId !== undefined && chainId !== chain.id,
    hasProvider: Boolean(eth) || options.length > 0 || Boolean(devAccount),
    connect,
    disconnect,
    switchNetwork,
    client,
  };
}
