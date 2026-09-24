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
const devKey = isLocal ? (import.meta.env.VITE_DEV_PRIVATE_KEY as `0x${string}` | undefined) : undefined;

export interface Wallet {
  address?: Address;
  chainId?: number;
  wrongNetwork: boolean;
  hasProvider: boolean;
  connect: () => Promise<void>;
  disconnect: () => void;
  switchNetwork: () => Promise<void>;
  client?: WalletClient;
}

export function useWallet(): Wallet {
  const eth = typeof window !== "undefined" ? window.ethereum : undefined;
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

  const connect = useCallback(async () => {
    if (devAccount) return;
    if (!eth) throw new Error("No wallet found. Install MetaMask, Rabby or Coinbase Wallet.");
    const accounts = (await eth.request({ method: "eth_requestAccounts" })) as Address[];
    const id = (await eth.request({ method: "eth_chainId" })) as string;
    setDisconnected(false);
    setAddress(accounts[0]);
    setChainId(Number(id));
  }, [eth, devAccount]);

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
  const disconnect = useCallback(() => setDisconnected(true), []);

  const active = disconnected ? undefined : address;

  const client = useMemo<WalletClient | undefined>(() => {
    if (!active) return undefined;
    if (devAccount) return createWalletClient({ account: devAccount, chain, transport: http(rpcUrl) });
    if (!eth) return undefined;
    return createWalletClient({ account: active, chain, transport: custom(eth) });
  }, [active, eth, devAccount]);

  return {
    address: active,
    chainId,
    wrongNetwork: active !== undefined && chainId !== undefined && chainId !== chain.id,
    hasProvider: Boolean(eth) || Boolean(devAccount),
    connect,
    disconnect,
    switchNetwork,
    client,
  };
}
