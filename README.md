# Options Vault

Fully on-chain automated covered-call vault on Arbitrum. Depositors supply WETH; each weekly epoch
the vault writes ~30-delta calls against the full balance, pricing them with an on-chain
Black-Scholes engine fed by a realized-volatility estimate the contract maintains itself.
Spot comes from Chainlink; premium comes from math the contract runs.

> **Testnet only. Not a financial product.**

## Contracts

| Contract | Role |
|---|---|
| `OptionsVault` (ERC-4626) | WETH custody, epoch state machine, share accounting |
| `PricingEngine` | Realized vol (O(1) accumulators) + fixed-point Black-Scholes (PRBMath) |
| `OptionToken` (ERC-1155) | One id per (strike, expiry) |
| `SettlementResolver` | Chainlink read, staleness checks, ITM/OTM payout |

Interfaces live in `src/interfaces/` and are the shared contract between workstreams.

## Scope (MVP)
One asset (WETH), fixed-delta strike rule, weekly epochs, Arbitrum Sepolia. Multi-asset, dynamic
delta and mainnet are stretch goals.

## Status
- [x] Phase 0: repo, interfaces, CI skeleton
- [x] Phase 1: PricingEngine
- [x] Phase 2: Vault + OptionToken (invariant-tested)
- [x] Phase 3: Oracle + settlement (Automation-driven; upkeep registration is a Phase 5 deploy step)
- [x] Phase 4: Security pass (see docs/security-report.md)
- [ ] Phase 5: Frontend + deploy
- [ ] Phase 6: Polish

See the full plan in `docs/action-plan.md`.

## Dev
```
git clone --recurse-submodules <repo>
forge build && forge test
```

## PricingEngine accuracy and limits
- Normal CDF: Abramowitz & Stegun 26.2.17, absolute error <= 7.5e-8. This propagates to price as
  roughly (S + K*e^-rT) * 7.5e-8 (about 1.5e-5 at S = 100). Tests derive their tolerances from
  this bound rather than an arbitrary epsilon.
- The approximation has a ~1e-9 discontinuity at x = 0 (N(0) is not exactly 0.5); inside the bound.
- `strikeForDelta` inverts delta by bisecting on d1 (no strike bracket, about 0.5M gas), then
  recovers the strike in closed form.
- Realized vol is `sum(r^2) / sum(dt)` over a rolling window using the real gap between snapshots
  (so a delayed snapshot does not inflate vol), clamped to [`minVolatility`, `maxVolatility`].
- Reference vectors: `script/gen_vectors.py` writes `test/vectors/bs_vectors.json` (400 cases,
  exact CDF via `math.erfc`, identical to `scipy.stats.norm.cdf`).

## Vault design notes (Phase 2)
- **Epoch flow:** `startEpoch` (keeper) -> `buyOptions` (anyone, USDC) -> `activate` (permissionless
  once sold out or the writing window closes) -> `beginSettlement` (after expiry) -> `settle`.
- **Strike and premium are fixed at `startEpoch`** from spot, realized vol and the 30-delta target,
  so buyers cannot game them during the writing window. Premium rounds up (favours the vault).
- **Deposits/withdrawals only in Idle**, so collateral cannot move mid-epoch. Idle lasts at least
  `idleWindow` after every epoch, so depositors always get an exit window.
- **Stale-quote guard:** `buyOptions` reverts if spot has moved more than `maxSpotDeviationBps` from
  the epoch-start spot. **Premium markup** (`premiumMarkupBps`) adds a cushion over fair value.
- **Unsold epochs are skipped:** if nothing is bought, the vault returns to Idle with no lock-up.
- **Premium is USDC, share price is WETH.** USDC premium streams to shareholders via a per-share
  accumulator (settled on every mint/burn/transfer), so it is not mixed into `totalAssets`.
- **Cash-settled in WETH:** payout per option = (S - K) / S, rounded down. `settle` reserves the
  total (`reservedPayout`, excluded from `totalAssets`); holders call `redeemOptions` to claim. Payout per
  option is always < 1 WETH, so payouts can never exceed locked collateral.
- **Virtual-share offset (3)** on the ERC-4626 to blunt first-depositor inflation attacks.

### Invariants (test/OptionsVault.invariant.t.sol)
Reserved payout backed by WETH balance; options sold <= collateral locked; per-epoch payouts <=
locked collateral; payout per option < 1; reserved payout covers all outstanding options; USDC
balance covers all claimable premium; share supply conserved. A mutation check (doubling the payout
formula) confirms the suite fails on a real accounting bug.

## Oracle, settlement and keeper (Phase 3)
- **Live spot** (`SettlementResolver.spot`): rejects non-positive answers, `answeredInRound < roundId`,
  future timestamps, and data older than `heartbeat + buffer`. An optional Arbitrum sequencer-uptime
  feed adds a down / grace-period check (disabled with `address(0)` on testnets).
- **Settlement price is not a spot read at trigger time.** It is the Chainlink round in effect at
  expiry: the last round with `updatedAt <= expiry`. Anyone may call `submitExpiryRound(epoch, roundId)`
  but only that one round is accepted, so the caller has no discretion and nothing in the settlement
  transaction can move the price. The feed must also have been fresh at expiry, otherwise settlement
  is refused rather than run on stale data.
  Exploit tests: post-expiry feed manipulation, cherry-picking an in-epoch spike, and skipping the
  price record all fail (`test/Stack.t.sol`).
- **VaultKeeper** is the single keeper for the engine and vault and is driven by one Chainlink
  Automation upkeep. `checkUpkeep` finds the next due action (settle, record price, begin settlement,
  activate, start epoch, hourly snapshot); `performUpkeep` is forwarder-only and re-derives the due
  action, so forged `performData` is rejected.
- **Vol floor and cap** (`minVolatility` / `maxVolatility`): found while testing. A flat market gives
  zero realized vol, `strikeForDelta` rejects that, and the keeper would retry `startEpoch` forever
  (epoch start frozen). Clamping fixes that and stops one price spike from producing an out-of-range
  strike. Regression tests cover both ends. Raw vol stays available via `rawVolatility()`.

### Known limitations / trust assumptions
- Trust the Chainlink ETH/USD feed and its heartbeat/deviation configuration.
- Chainlink phase changes are handled (successor lookup crosses phase boundaries). If the feed was
  stale at expiry, settlement is refused until `fallbackDelay` has passed, then the same
  deterministic round is accepted, so an oracle outage delays settlement but cannot lock funds.
- The full pre-Phase-4 design audit (14 fixes, accepted risks) is in `docs/pre-p4-audit.md`.
- Realized vol is sampled from the same feed, so it inherits the feed's update cadence (a stale
  answer repeated across samples looks like zero vol; the floor covers that).
