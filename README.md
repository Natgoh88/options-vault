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
- [ ] Phase 1: PricingEngine
- [ ] Phase 2: Vault + OptionToken
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
