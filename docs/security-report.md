# Security report

Testnet-only project; not audited by a third party. This is our own review, written so that a
reader can check every claim against a test or a tool run.

## 1. Scope and method

Contracts in `src/`: `OptionsVault`, `PricingEngine`, `OptionToken`, `SettlementResolver`,
`VaultKeeper` (plus interfaces). Steps, in order:

1. Manual design audit after Phase 3: 14 fixes, see `docs/pre-p4-audit.md`.
2. Static analysis: Slither 0.11.6 (`slither . --fail-high`, enforced in CI) and Aderyn 0.6.8
   (runs in CI on Linux, report uploaded as a build artifact).
3. Manual review against the standard list (section 4).
4. Exploit and access-control tests, mutation checks, coverage, invariants at scale.
5. Second full design audit after Phase 5, covering keeper, deployment and frontend: 7 fixes,
   see `docs/post-p5-audit.md`.

## 2. Results at a glance

| Check | Result |
|---|---|
| Test suite | 126 tests, 0 failing (16 suites) |
| Line coverage, `src/` | **100%** for every contract (branch coverage 89.7% overall) |
| Fuzz | 1,000 runs per fuzz test |
| Invariants (8) | 256 runs default; **10,000 runs (640,000 calls) and 50,000 runs (3,200,000 calls), 0 reverts, all hold** |
| Mutation checks | Doubling the payout formula fails 2 invariants; removing `nonReentrant` from `buyOptions` fails all 3 tests that re-enter a guarded function; removing the minimum-fill check fails the griefing exploit test; reverting the keeper fix fails the boundary test; removing the keeper's supply guard fails the donation test |
| Slither | 0 High, 10 Medium, 17 Low, 3 Informational; all triaged below |
| Aderyn | 1 High category (9 instances, all false positives), 13 Low categories; triaged below |

## 3. Slither triage (30 results)

| Detector | Count | Impact | Disposition | Reasoning |
|---|---|---|---|---|
| reentrancy-benign | 1 (fixed) | Low | **Fixed** | `redeemOptions` updated `reservedPayout` after the option-token burn. Not exploitable (function is `nonReentrant`, token is our own contract) but reordered to checks-effects-interactions. Slither no longer reports it. |
| incorrect-equality | 1 | Medium | False positive | `locked == 0 \|\| totalSupply() == 0` is a guard against an empty vault. Nothing an attacker can influence makes a non-zero value read as zero (donations only increase balances). |
| unused-return | 9 | Medium | False positive / intentional | Eight are Chainlink tuple returns where only some fields are needed (e.g. `latestRoundData` for `updatedAt`). One is `submitExpiryRound`'s return value, which the keeper does not need. Two are `try resolver.x()` used purely as "does it revert" health checks. |
| missing-zero-check | 1 | Low | Accepted | `setForwarder(address(0))` is deliberate: it is an owner kill-switch that disables `performUpkeep`. |
| calls-loop | 2 | Low | Accepted | Bounded (<= 100 linear + <= 64 binary-search steps), only in the keeper's view path, each call wrapped in `try/catch`. Worst case is a delayed upkeep, and it only runs when settlement was already late. |
| reentrancy-events | 2 | Low | Accepted | `performUpkeep` emits events after a self-call to `execute`, which only calls our own trusted contracts. Event ordering only. |
| timestamp | 12 | Low | Accepted | Time is the mechanism (epoch length, idle window, heartbeat). Windows are hours to days; the few-seconds skew a sequencer can introduce is not material. |
| assembly | 1 | Info | Accepted | Memory-safe revert bubbling in `performUpkeep`. |
| cyclomatic-complexity | 1 | Info | Accepted | `submitExpiryRound` has many independent validity checks; each has a dedicated test. |
| unindexed-event-address | 1 | Info | Accepted | `VaultKeeper.Initialised` indexes three of its four addresses (the EVM limit); the feed address is unindexed. |

## 3b. Aderyn triage

| Finding | Instances | Disposition | Reasoning |
|---|---|---|---|
| H-1 Reentrancy: state change after external call | 9 | False positive | Every flagged call is to a `view` function (`spot`, `realizedVolatility`, `strikeForDelta`, `callPrice`, `snapshotSettlementPrice`, `epochData`, `latestRoundData`, `decimals`), compiled to STATICCALL, which cannot modify state. Two instances are in constructors. The state-changing paths that do call out (`buyOptions`, `redeemOptions`, `claimPremium`) are `nonReentrant`, follow checks-effects-interactions, and are covered by the reentrancy tests. |
| L-1 Centralization risk | 2 | Accepted | Documented: the owner can only rotate the vault keeper, which cannot set prices or move funds. |
| L-4 Local variable shadows state variable | 7 | Accepted | Fields of the constructor `Params` struct share names with the immutables they initialise; intentional and unambiguous. |
| L-6 PUSH0 opcode | 5 | Accepted | Arbitrum supports PUSH0 (Shanghai) since ArbOS 11. |
| L-7 Loop contains revert | 1 | False positive | The bisection loop in `strikeForDelta` has a fixed iteration count; the reverts are input validation before the loop. |
| L-8 State change without event | 1 | **Fixed** | `VaultKeeper.init` now emits `Initialised`. |
| L-9 Address set without zero check | 1 | Accepted | `setForwarder(address(0))` is the deliberate kill-switch (same as the Slither item). |
| L-10 Unchecked return | 1 | Accepted | Keeper does not need `submitExpiryRound`'s returned price. |
| L-11 Uninitialized local | 2 | False positive | Loop counters default to zero by definition. |
| L-12 Unspecific pragma | 5 | Accepted | Only interfaces use `^0.8.26`, so integrators can import them; deployable contracts pin `0.8.26`. |
| L-2, L-3, L-5, L-13 | 27 | Style | Numeric-literal style, a single-use modifier and public-vs-external visibility; no security effect. |

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
| A-1 | Med | Dust purchase (one USDC base unit) locked the whole vault for an epoch | Fixed: minimum fill, cancellation and refunds; exploit test |
| A-2 | Low | Option token id collision possible with `idleWindow = 0` | Fixed: `idleWindow > 0` required |
| A-3 | Low | Keeper retried a reverting `StartEpoch` after a donation to a share-less vault | Fixed |
| A-4 | Med | Automation upkeeps reverted when simulation and execution straddled a lifecycle boundary | Fixed: execute what is due at execution time |
| A-5 | High (deploy) | Frontend build failed on a fresh clone (Vercel) | Fixed; CI builds the frontend |
| A-6 | Low | Dev signer key compiled into production bundles | Fixed; CI checks `dist/` |
| AD-L8 | Low | `VaultKeeper.init` emitted no event | Fixed |

No unfixed High or Medium issue is known. That is not the same as none existing.

## 6. Invariants at scale

The suite has 8 invariants; `cancelledEpochsAreInert` and the refund-aware `premiumSolvent` were
added with the minimum-fill change.


- 10,000 runs / 640,000 calls / 0 reverts (before the pre-Phase-4 hardening changes).
- **50,000 runs / 3,200,000 calls / 0 reverts, all 7 invariants hold**, on the hardened contracts
  (run before the final checks-effects-interactions reorder of `redeemOptions`, which the default
  256-run invariant suite and the reentrancy tests have covered since).
- A nightly / on-demand workflow (`invariants-deep.yml`) repeats the 50,000-run campaign in CI.

## 7. Known limitations (not fixable in the MVP)

See "Accepted / documented" in `docs/pre-p4-audit.md`. The main ones: economic model risk (realized
vol vs implied), Chainlink trust, full-balance lock-up, USDC premium exposure, no third-party audit.
