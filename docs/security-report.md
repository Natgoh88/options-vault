# Security report (Phase 4)

Testnet-only project; not audited by a third party. This is our own review, written so that a
reader can check every claim against a test or a tool run.

## 1. Scope and method

Contracts in `src/`: `OptionsVault`, `PricingEngine`, `OptionToken`, `SettlementResolver`,
`VaultKeeper` (plus interfaces). Steps, in order:

1. Manual design audit after Phase 3: 14 fixes, see `docs/pre-p4-audit.md`.
2. Static analysis: Slither 0.11.6 (`slither . --fail-high`, also enforced in CI).
   Aderyn was **not** run (tool not installed on the dev machine; can be added later).
3. Manual review against the standard list (section 4).
4. Exploit and access-control tests, mutation checks, coverage, invariants at scale.

## 2. Results at a glance

| Check | Result |
|---|---|
| Test suite | 110 tests, 0 failing (13 suites) |
| Line coverage, `src/` | **100%** for every contract (branch coverage 89.8% overall) |
| Fuzz | 1,000 runs per fuzz test |
| Invariants (7) | 256 runs default; **10,000 runs, 640,000 calls, 0 reverts, all hold**; 50,000-run result: see section 6 |
| Mutation checks | Doubling the payout formula fails 2 invariants; removing `nonReentrant` from `buyOptions` fails all 3 tests that re-enter a guarded function |
| Slither | 0 High, 10 Medium, 16 Low, 2 Informational; all triaged below |

## 3. Slither triage (28 results)

| Detector | Count | Impact | Disposition | Reasoning |
|---|---|---|---|---|
| reentrancy-benign | 1 (fixed) | Low | **Fixed** | `redeemOptions` updated `reservedPayout` after the option-token burn. Not exploitable (function is `nonReentrant`, token is our own contract) but reordered to checks-effects-interactions. Slither no longer reports it. |
| incorrect-equality | 1 | Medium | False positive | `locked == 0 \|\| totalSupply() == 0` is a guard against an empty vault. Nothing an attacker can influence makes a non-zero value read as zero (donations only increase balances). |
| unused-return | 9 | Medium | False positive / intentional | Eight are Chainlink tuple returns where only some fields are needed (e.g. `latestRoundData` for `updatedAt`). One is `submitExpiryRound`'s return value, which the keeper does not need. Two are `try resolver.x()` used purely as "does it revert" health checks. |
| missing-zero-check | 1 | Low | Accepted | `setForwarder(address(0))` is deliberate: it is an owner kill-switch that disables `performUpkeep`. |
| calls-loop | 2 | Low | Accepted | Bounded (<= 100 linear + <= 64 binary-search steps), only in the keeper's view path, each call wrapped in `try/catch`. Worst case is a delayed upkeep, and it only runs when settlement was already late. |
| reentrancy-events | 2 | Low | Accepted | `performUpkeep` emits events after a self-call to `execute`, which only calls our own trusted contracts. Event ordering only. |
| timestamp | 11 | Low | Accepted | Time is the mechanism (epoch length, idle window, heartbeat). Windows are hours to days; the few-seconds skew a sequencer can introduce is not material. |
| assembly | 1 | Info | Accepted | Memory-safe revert bubbling in `performUpkeep`. |
| cyclomatic-complexity | 1 | Info | Accepted | `submitExpiryRound` has many independent validity checks; each has a dedicated test. |

## 4. Manual review against the standard list

**Reentrancy on withdraw / claim / redeem.**
`buyOptions`, `redeemOptions` and `claimPremium` are `nonReentrant`; all state is updated before
external calls. The only callback surface is the ERC-1155 receive hook on `buyOptions`.
`ReentrantBuyer` in `test/Security.t.sol` re-enters from that hook into `buyOptions`,
`claimPremium`, `redeemOptions` (each rejected with `ReentrancyGuardReentrantCall`) and `deposit`
(rejected by `maxDeposit == 0`). Re-entering `activate()` after a sell-out is permitted and shown to
see consistent accounting. Removing the guard makes the tests fail (mutation check).
ERC-4626 `withdraw`/`redeem` only move WETH, which has no hooks.

**Oracle manipulation at the settlement snapshot.**
The settlement price is the last Chainlink round with `updatedAt <= expiry`, submitted by anyone but
with exactly one valid answer. Exploit tests (`test/Stack.t.sol`, `test/Hardening.t.sol`):
post-expiry feed manipulation cannot be submitted (`RoundAfterExpiry`); an in-epoch spike cannot be
cherry-picked (`NotLastRoundBeforeExpiry`); settlement cannot start without a recorded price; a stale
feed at expiry is refused until the fallback delay; phase changes are handled. Spot for strike
selection has staleness, non-positive, future-timestamp and sequencer checks. Remaining trust: the
Chainlink feed itself.

**Access control on epoch transitions.**
`startEpoch` is keeper-only; `activate`, `beginSettlement` and `settle` are permissionless but
state- and time-gated (a wrong call reverts). `OptionToken.mint/burn` are vault-only;
`PricingEngine.recordSnapshot` is keeper-only; `SettlementResolver.setVault` and
`OptionToken.setVault` are deployer-only and one-shot; `VaultKeeper.performUpkeep` is
forwarder-only and re-derives the due action. `test_accessControlMatrix` and
`test_keeperAndResolverAccessControl` cover the matrix. Owner is `Ownable2Step`; its only power is
rotating the vault keeper, which cannot move funds.

**Rounding direction.**
Premium rounds up (per option and in total), payouts and premium-per-share round down, ERC-4626
shares use OpenZeppelin's vault-favouring rounding. Tests: `testFuzz_depositThenRedeemNeverProfits`,
`testFuzz_splitBuyingNeverCheaper`, `testFuzz_payoutRoundsDown`, plus the invariants.

**Share-price manipulation (ERC-4626 inflation).**
Virtual-share offset of 3. `test_inflationAttackFailsToStealVictimDeposit`: attacker deposits 1 wei,
donates 100 WETH; victim still gets back >= 99% of a 50 WETH deposit and the attacker cannot profit.

**Economic / logic issues found by review** (all fixed, all with regression tests): see
`docs/pre-p4-audit.md` (idle-window lock-in, oracle-outage lock-up, stale-quote arbitrage,
missing pricing margin, mis-annualised vol, keeper starvation, flat-market epoch freeze).

## 5. Findings log

| ID | Sev | Finding | Status |
|---|---|---|---|
| P3-1 | Med | Keeper offered `SubmitRound` at `timestamp == expiry`, resolver rejected it | Fixed, found by reasoning before test |
| P3-2 | Med | Flat price window gives zero vol, `strikeForDelta` reverts, epoch start frozen | Fixed (vol floor/cap), regression tests |
| PRE4-1..14 | High..Low | See `docs/pre-p4-audit.md` | Fixed |
| P4-1 | Info | `redeemOptions` violated checks-effects-interactions (not exploitable) | Fixed, Slither clean |

No unfixed High or Medium issue is known. That is not the same as none existing.

## 6. Invariants at scale

- 10,000 runs / 640,000 calls / 0 reverts (ran before the pre-Phase-4 hardening changes).
- 50,000-run campaign on the hardened contracts: see the note appended below once it completes.
  A nightly/on-demand workflow (`invariants-deep.yml`) repeats it in CI.

## 7. Known limitations (not fixable in the MVP)

See "Accepted / documented" in `docs/pre-p4-audit.md`. The main ones: economic model risk (realized
vol vs implied), Chainlink trust, full-balance lock-up, USDC premium exposure, no third-party audit.
