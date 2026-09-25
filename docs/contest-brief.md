# Contest brief (CodeHawks First Flight or similar)

Everything a contest platform asks for, ready to paste into a submission.

## Summary

An automated covered-call vault. Depositors supply WETH (ERC-4626). Each epoch the vault sells
~30-delta European calls, cash-settled in WETH and paid for in USDC. It prices them with an on-chain
Black-Scholes engine fed by a realized-volatility estimate it maintains from Chainlink snapshots,
and settles against the Chainlink round in effect at expiry.

## Scope

```
src/OptionsVault.sol          249 nSLOC
src/PricingEngine.sol         192
src/VaultKeeper.sol           176
src/SettlementResolver.sol    114
src/OptionToken.sol            32
src/interfaces/*.sol          153
                              ---
                              916
```

Out of scope: `src/testnet/TestUSDC.sol` (faucet stand-in), `script/`, `test/`, `frontend/`, and
issues in OpenZeppelin or PRBMath.

- Solidity 0.8.26, Foundry. Chain: Arbitrum (Sepolia for the live deployment).
- Tokens: WETH (collateral) and USDC (6 decimals, premium). No fee-on-transfer or rebasing tokens.

## Roles

| Role | Powers |
|---|---|
| Owner (`Ownable2Step`) | `setKeeper` on the vault. Nothing else: no pause, no upgrade, no fees, no withdrawal. |
| Keeper (the `VaultKeeper` contract) | `startEpoch`, `recordSnapshot`, only when due; cannot set prices. |
| Automation forwarder | calls `VaultKeeper.performUpkeep`, which executes whatever is due. |
| Anyone | deposit/withdraw (Idle only), `buyOptions`, `activate`, `beginSettlement`, `settle`, `submitExpiryRound`, `redeemOptions`, `claimPremium`. |

## Invariants we believe hold

1. WETH balance ≥ `reservedPayout` (reserved option payouts are always backed).
2. Per epoch, options sold ≤ collateral locked, and WETH paid out ≤ sold × payout-per-option ≤
   collateral locked.
3. Payout per option < 1 WETH.
4. USDC balance ≥ claimable premium + refunds owed on cancelled epochs; nothing is paid twice.
5. A cancelled epoch pays no WETH and refunds at most what it collected.
6. The settlement price for an epoch is uniquely determined by the Chainlink round history.
7. Rounding always favours the vault (premium up; payouts, refunds and shares down).

These are encoded in `test/OptionsVault.invariant.t.sol` and run at 50,000 runs nightly.

## Known issues (do not submit)

- Realized vol differs from implied vol; the vault can underprice options (model risk).
- The whole balance is locked for an epoch above the 10% minimum fill, even if not fully sold.
- Normal CDF approximation error ≤ 7.5e-8 per evaluation (documented bound).
- Chainlink is trusted. Settlement waits `fallbackDelay` if the feed was stale at expiry.
- The keeper's round finder assumes consecutive round ids within an aggregator phase. Anyone can
  still submit the correct round manually.
- Someone can force an epoch to run by buying exactly the minimum fill (they pay full premium).
- Static-analysis findings already triaged in `docs/security-report.md`.

## Prior review

Two internal design audits (`docs/pre-p4-audit.md`, `docs/post-p5-audit.md`), Slither, Aderyn,
and the security report. No third-party audit.

## Build

```bash
git clone --recurse-submodules https://github.com/Natgoh88/options-vault.git
cd options-vault && forge build && forge test
```
