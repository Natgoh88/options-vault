# Pre-Phase-4 design audit

Manual review of all contracts after Phase 3, before running static analysis. Every item below was
either fixed (with a test) or explicitly accepted. Static-analysis findings (Slither/Aderyn) are
tracked separately in the Phase 4 report.

## Fixed

| # | Sev | Finding | Fix | Test |
|---|-----|---------|-----|------|
| 1 | High | **Depositors effectively locked in.** Deposits/withdrawals only work in Idle, but Automation started the next epoch in the same upkeep loop as settlement, so Idle lasted about one transaction. | `idleWindow`: `startEpoch` requires the vault to have been Idle for a minimum time; the keeper respects it. | `test_idleWindowBlocksImmediateRestartAndAllowsExit`, `test_keeperRespectsIdleWindow` |
| 2 | High | **Oracle outage or Chainlink phase change could lock collateral in Active forever.** Settlement refused a stale-at-expiry feed with no way out, and the successor check ignored phase boundaries (`roundId + 1` does not exist across a phase change). | Successor lookup handles `((phase+1) << 64) \| 1`. After `fallbackDelay` the same deterministic "last round <= expiry" rule is accepted without the freshness requirement. | `test_phaseChange*`, `test_staleAtExpiryAcceptedAfterFallbackDelay` |
| 3 | Med | **Stale-quote arbitrage.** Strike and premium are fixed at epoch start; a buyer could wait for spot to move and buy underpriced calls during the writing window. | `maxSpotDeviationBps`: `buyOptions` reverts if spot is outside the band around `spotAtStart`. | `test_buyRevertsWhenSpotMovedBeyondBand` |
| 4 | Med | **No margin over fair value.** Selling at exactly Black-Scholes leaves no cushion for CDF error, vol estimation error or adverse selection. | `premiumMarkupBps` (capped at 50%), rounded up. | `test_premiumIncludesMarkup` |
| 5 | Med | **Vol estimator mis-annualised delayed snapshots.** A 1% move over 24h was counted like a 1% move over 1h (fixed-interval assumption). | Estimator is now `sum(r^2) / sum(dt)` using actual gaps (zero-mean). | `test_delayedSnapshotsDoNotInflateVol` |
| 6 | Med | **A failing lifecycle action starved snapshots** (the keeper always returned the failing action first). | `performUpkeep` runs actions via `try this.execute`; on failure it still records a due snapshot, otherwise it bubbles the revert so Automation does not send a no-op. | `test_failingActionStillRecordsDueSnapshot` |
| 7 | Med | **Keeper could not locate the expiry round if delayed by more than 100 rounds.** | Linear scan, then binary search over the aggregator round range. | `test_keeperFindsExpiryRoundBeyondLinearLookback` |
| 8 | Med | Flat market gives zero realized vol, `strikeForDelta` reverts, epoch start freezes (found in Phase 3). | Vol floor and cap. | `test_flatMarketVolClampedToFloor`, `test_spikeVolClampedToCap` |
| 9 | Low | **Unsold epochs locked collateral for a week.** | If nothing is sold, `activate` skips the epoch and returns to Idle. | `test_unsoldEpochIsSkippedAndCollateralFreedImmediately` |
| 10 | Low | `strikeForDelta` cost about 1.3M gas and reverted outside [S/4, 4S]. | Bisect in d1-space with a closed-form strike: about 0.48M gas, no bracket. | `test_strikeSolverIsCheap`, `test_strikeForDeltaExtremeInputsResolve` |
| 11 | Low | Keeper could start an epoch on stale vol. | Start only when a snapshot was taken within the last interval. | `test_keeperTakesFreshSnapshotBeforeStartingEpoch` |
| 12 | Low | `redeem(uint256,uint256)` overloaded ERC-4626 `redeem(uint256,address,address)` (integrator footgun). | Renamed `redeemOptions`. | all vault tests |
| 13 | Low | A zero-premium epoch would give options away. | `ZeroPremium` revert. | defensive |
| 14 | Low | Hygiene: `Ownable` to `Ownable2Step`; zero-address checks; sequencer feed `startedAt == 0` treated as invalid; events on one-time wiring; fixed compiler pragma on deployable contracts. | Various. | `test_ownershipIsTwoStepAndKeeperCannotBeZero`, `test_invalidSequencerRoundRejected`, constructor tests |

## Accepted / documented (not fixable in the MVP)

- **Model risk.** Black-Scholes priced off *realized* vol can under- or over-charge relative to what
  the market implies. The markup is a cushion, not a guarantee; the vault can lose money.
- **Oracle trust.** Chainlink ETH/USD and its heartbeat/deviation settings are trusted. The design
  removes discretion and same-transaction manipulation, not oracle-level compromise.
- **The whole balance is locked** even when only part of it was sold (the unsold portion earns
  nothing). Simple and safe; a partial-release design is a stretch goal.
- **Round-id assumption.** Successor lookup and the keeper's binary search assume aggregator round
  ids within a phase are consecutive (true for OCR aggregators). If not, settlement can still be
  submitted manually with the right round id.
- **USDC risk.** Premium is paid in USDC; a depeg or blacklist affects only premium claims
  (pull-based), not WETH collateral.
- **Immutable wiring.** The engine keeper and the vault/resolver/token links are set once; changing
  them means redeploying. The owner can only rotate the vault keeper, which can start epochs and
  take snapshots but cannot move funds.
- **No price sandwiching.** Price and strike are fixed per epoch, so there is no per-trade price to
  sandwich.
