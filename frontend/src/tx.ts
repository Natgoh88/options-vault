import { useCallback, useRef, useState } from "react";
import { BaseError, type Hash, type WalletClient } from "viem";
import { publicClient } from "./chain";

export interface Toast {
  id: number;
  title: string;
  status: "pending" | "success" | "error";
  hash?: Hash;
  message?: string;
}

function readable(e: unknown): string {
  if (e instanceof BaseError) {
    const msg = e.shortMessage || e.message;
    if (/user rejected|denied/i.test(msg)) return "Rejected in wallet";
    return msg;
  }
  return (e as Error)?.message ?? "Transaction failed";
}

/**
 * Sends one transaction at a time per call, tracks it as a toast, and resolves true once the
 * receipt is a success. `onSettled` runs after every attempt so the UI can refetch.
 */
export function useTxs(client: WalletClient | undefined, onSettled: () => void) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);

  const patch = useCallback((id: number, p: Partial<Toast>) => {
    setToasts((ts) => ts.map((t) => (t.id === id ? { ...t, ...p } : t)));
  }, []);

  const dismiss = useCallback((id: number) => {
    setToasts((ts) => ts.filter((t) => t.id !== id));
  }, []);

  const run = useCallback(
    async (title: string, send: (c: WalletClient) => Promise<Hash>): Promise<boolean> => {
      if (!client) return false;
      const id = nextId.current++;
      setToasts((ts) => [...ts, { id, title, status: "pending", message: "Confirm in your wallet" }]);
      try {
        const hash = await send(client);
        patch(id, { hash, message: "Waiting for confirmation" });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("Transaction reverted");
        patch(id, { status: "success", message: undefined });
        setTimeout(() => dismiss(id), 6000);
        return true;
      } catch (e) {
        patch(id, { status: "error", message: readable(e) });
        setTimeout(() => dismiss(id), 9000);
        return false;
      } finally {
        onSettled();
      }
    },
    [client, dismiss, onSettled, patch],
  );

  return { toasts, run, dismiss };
}

/** Thin wrapper so call sites stay one line; the wallet client already carries account + chain. */
export function writeTx(
  c: WalletClient,
  address: `0x${string}`,
  abi: readonly unknown[],
  functionName: string,
  args: readonly unknown[] = [],
  value?: bigint,
): Promise<Hash> {
  return c.writeContract({
    address,
    abi,
    functionName,
    args,
    value,
    account: c.account!,
    chain: c.chain,
  } as never);
}
