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
- [ ] Phase 3: Oracle + settlement
- [ ] Phase 4: Security pass
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
- `strikeForDelta` bisects over [S/4, 4S] and reverts if the target delta is not bracketed
  (e.g. 10-delta at 300% vol and 60 days). Fine for the weekly ~30-delta use case.
- Reference vectors: `script/gen_vectors.py` writes `test/vectors/bs_vectors.json` (400 cases,
  exact CDF via `math.erfc`, identical to `scipy.stats.norm.cdf`).

## Vault design notes (Phase 2)
- **Epoch flow:** `startEpoch` (keeper) -> `buyOptions` (anyone, USDC) -> `activate` (permissionless
  once sold out or the writing window closes) -> `beginSettlement` (after expiry) -> `settle`.
- **Strike and premium are fixed at `startEpoch`** from spot, realized vol and the 30-delta target,
  so buyers cannot game them during the writing window. Premium rounds up (favours the vault).
- **Deposits/withdrawals only in Idle**, so collateral cannot move mid-epoch.
- **Premium is USDC, share price is WETH.** USDC premium streams to shareholders via a per-share
  accumulator (settled on every mint/burn/transfer), so it is not mixed into `totalAssets`.
- **Cash-settled in WETH:** payout per option = (S - K) / S, rounded down. `settle` reserves the
  total (`reservedPayout`, excluded from `totalAssets`); holders call `redeem` to claim. Payout per
  option is always < 1 WETH, so payouts can never exceed locked collateral.
- **Virtual-share offset (3)** on the ERC-4626 to blunt first-depositor inflation attacks.

### Invariants (test/OptionsVault.invariant.t.sol)
Reserved payout backed by WETH balance; options sold <= collateral locked; per-epoch payouts <=
locked collateral; payout per option < 1; reserved payout covers all outstanding options; USDC
balance covers all claimable premium; share supply conserved. A mutation check (doubling the payout
formula) confirms the suite fails on a real accounting bug.
