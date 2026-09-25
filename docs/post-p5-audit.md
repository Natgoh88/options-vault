# Post-Phase-5 audit

A second full review, done after the frontend and deploy tooling existed, so it covers the whole
system as a user would meet it: contracts, keeper, deployment and UI. Every fix below has a test,
and each contract or keeper fix was **mutation-checked**: the test was run against the unfixed code
and shown to fail.

## Fixed

| # | Sev | Finding | Fix | Test (fails without the fix) |
|---|-----|---------|-----|------|
| A-1 | Med | **Dust purchase locks the vault.** Unsold epochs were skipped only if *nothing* sold. Buying 1 wei of options (cost: one USDC base unit, $0.000001) forced a full epoch in which every depositor's WETH was locked while earning essentially nothing. | `minFillBps` (10% in both deploy profiles). Below it, `activate` **cancels** the epoch: the vault returns to Idle immediately, the collected premium is never credited to shareholders, and buyers reclaim it through `redeemOptions` (refund rounds down, purchase rounded up, so refunds never exceed collections). | `test_exploit_dustPurchaseCannotLockVault`, `test_underFilledEpochRefundsBuyersAndPaysNoPremium`, invariants `premiumSolvent` (now includes refunds owed) and `cancelledEpochsAreInert` |
| A-2 | Low | **Option token id collision.** Ids are `keccak(strike, expiry)`. With `idleWindow = 0`, a cancelled epoch and the next one could start in the same block at the same strike and share an id, letting holders of one redeem against the other. | Constructor requires `idleWindow > 0`, so expiries are strictly increasing. | `test_zeroIdleWindowRejected`, `test_optionIdsUniqueAcrossEpochs` |
| A-3 | Low | **Keeper loop on a donation.** WETH sent to a vault with no shareholders made the keeper propose `StartEpoch` every run, which always reverts (`NothingToLock`). | Keeper also requires `totalSupply() > 0`. | `test_keeperIgnoresDonationWithNoShareholders` |
| A-4 | Med | **Upkeeps fail at lifecycle boundaries.** Automation simulates `checkUpkeep` in one block and executes in a later one. `performUpkeep` demanded that the simulated action still be exactly the top-priority one, so an upkeep simulated as "snapshot" just before the writing window closed reverted `NotNeeded` once it landed. Found when the local seeding harness crashed on it. | `performUpkeep` ignores `performData` and executes whatever is due at execution time. Stale simulations succeed; forged data can no longer select an action at all. | `test_staleSimulationAcrossBoundaryStillPerforms`, `test_forgedPerformDataIgnored` |
| A-5 | High (deploy) | **Frontend could not deploy.** The app imported the gitignored `deployments.local.json`; on a fresh clone (which is exactly what Vercel builds) the build failed. | Glob import that tolerates the missing file, read only in dev builds. CI now runs the production build. | CI `frontend` job; build verified with the file removed |
| A-6 | Low | **Dev signer key compiled into production.** Vite inlines `import.meta.env.VITE_*` at build time, so a local `npm run build` embedded the anvil key in `dist/` even though it was ignored at runtime. A real key placed there would have shipped the same way. | Read only under `import.meta.env.DEV` (a compile-time `false` in production, so the code is dropped). CI greps `dist/` for it. | CI `frontend` job |
| A-7 | UX | **One wallet only.** The app used `window.ethereum`, so with several wallets installed the user could not choose. | EIP-6963 discovery with a picker; the choice is remembered. | manual |

## Tooling added

- **Aderyn** runs in CI (Linux; it has no Windows build) and uploads its report as an artifact.
  Triage is in the security report.
- **Frontend CI job:** `npm ci`, type-check, production build, and the key-leak check above.
- **Branch protection on `main`:** `test` and `slither` must pass; no force-push or deletion.

## Considered and not changed

- **Mid-epoch withdrawal of unsold collateral.** It is tempting to release the unsold part during
  Active. But losses are only realised at settlement, so a depositor could withdraw once ETH ran
  above the strike and leave the loss to everyone else. Doing this safely needs mark-to-market
  share pricing. It remains a stretch goal; the minimum fill bounds the waste instead.
- **Minimum purchase size.** It would not stop griefing (buy the minimum repeatedly) and hurts
  small buyers. The minimum fill addresses the actual harm.
- **Griefing at exactly the minimum fill.** Someone can still force an epoch by buying 10%. They
  pay the full premium for it, which goes to depositors, so this is ordinary trade, not an attack.
