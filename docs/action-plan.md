# On-Chain Covered-Call Options Vault: Action Plan

## The idea

We're building a fully on-chain automated covered-call vault on Arbitrum. Depositors put WETH into the vault. Every epoch (weekly), the vault writes covered calls at a target delta (around 30-delta) against the full deposited balance, computing the strike and premium itself using an on-chain Black-Scholes pricing engine fed by a realized-volatility estimate the contract maintains from its own price history. No off-chain matching, no manual pricing, no subjective settlement. Price comes from Chainlink, premium comes from math the contract runs itself.

That last part is the actual differentiator. Computing Black-Scholes on-chain in fixed-point Solidity, including the normal CDF, is real engineering, not a wrapper around someone else's pricing. It puts us in the same category as Dopex's SSOVs (Arbitrum, same covered-call pattern), but Dopex doesn't need to justify its pricing model to a reviewer the way we will, because we're implementing it ourselves. That's the thing worth defending in a review, an interview, or a contest submission.

## Architecture

Four contracts, one Foundry project, standard `src/`, `test/`, `script/` layout.

1. **OptionsVault** (ERC-4626): holds WETH collateral, runs the epoch state machine, handles depositor share accounting.
2. **PricingEngine**: realized volatility calculation plus fixed-point Black-Scholes. Kept fully separate from the vault so it can be unit tested and fuzzed in isolation from anything that touches custody.
3. **OptionToken** (ERC-1155): one token ID per (strike, expiry) pair. Minted to buyers on purchase, burned on settlement.
4. **SettlementResolver**: reads the Chainlink ETH/USD feed at expiry, computes in-the-money or out-of-the-money, triggers vault settlement and payouts.

Off-chain: one keeper, a Chainlink Automation upkeep, doing two jobs: writing periodic price snapshots into PricingEngine's rolling window for the volatility calculation, and triggering the epoch roll and settlement at the correct timestamps.

## Step-by-step build plan

### Phase 0: Setup (day 1)
- [ ] Foundry project scaffolded, remappings for OpenZeppelin and PRBMath
- [ ] GitHub repo, branch protection, CI skeleton (`forge test`, `forge fmt --check` on every push)
- [ ] Arbitrum Sepolia RPC and faucet ETH for both wallets, encrypted keystores via `cast wallet import`, nothing in `.env`
- [ ] Write every contract's external function signatures as Solidity interfaces before either person writes implementation logic, so PricingEngine and OptionsVault can be built in parallel without blocking each other

### Phase 1: Pricing engine (front-load this, it's the hard part)
- [ ] Import PRBMath (SD59x18) for fixed-point exp and ln
- [ ] Realized volatility: keeper writes price snapshots into a ring buffer, maintain a running sum and sum-of-squares (accumulator pattern, same reason Week 6's reward math avoids looping over stakers) so volatility updates in O(1) instead of recomputing over the whole window every time
- [ ] Black-Scholes call price: `C = S*N(d1) - K*e^(-rT)*N(d2)`, with `d1 = [ln(S/K) + (r + vol^2/2)*T] / (vol*sqrt(T))` and `d2 = d1 - vol*sqrt(T)`
- [ ] Normal CDF N(x): Abramowitz-Stegun rational approximation (bounded error around 1.5e-7, no erf needed, just a polynomial plus exp)
- [ ] Fuzz tests: price should be monotonic in volatility, monotonic in moneyness, and always within the approximation's known error bound against precomputed reference values (generate test vectors from Python's scipy, check them into the repo)

### Phase 2: Vault and option token
- [ ] Deposit, withdraw, and share accounting on OptionsVault
- [ ] Epoch state machine: Idle to Writing to Active to Settling to Idle
- [ ] Strike selection at epoch start calls PricingEngine, mints OptionToken to the buyer, buyer pays premium in USDC
- [ ] Invariant test: vault collateral plus everything paid out to option holders never exceeds what was locked at epoch start, run at 10,000-plus runs

### Phase 3: Oracle and settlement
- [ ] Chainlink ETH/USD feed on Arbitrum Sepolia, staleness check that rejects if `updatedAt` is older than the feed's heartbeat plus a buffer
- [ ] SettlementResolver reads price at expiry, computes payout, calls the vault to release funds
- [ ] Chainlink Automation upkeep registered for epoch roll and periodic snapshot writing

### Phase 4: Security pass
- [ ] Slither and Aderyn across all four contracts, triage every finding as fixed, false positive with reasoning, or accepted risk with reasoning
- [ ] Manual review against the standard list: reentrancy on withdraw, oracle manipulation at the settlement snapshot, access control on epoch transitions, rounding direction favoring the vault everywhere it matters
- [ ] Write an exploit test for anything real found, then the fix, then a passing test proving the fix
- [ ] 90%+ line coverage, invariant tests run at 50,000-plus runs

### Phase 5: Frontend and deployment
- [ ] Deposit, withdraw, current epoch status, live Greeks display
- [ ] Deploy and verify all four contracts on Arbitrum Sepolia
- [ ] Wire frontend to deployed addresses, deploy to Vercel

### Phase 6: Polish
- [ ] README covering architecture, trust assumptions, and known limitations (CDF approximation error bound, oracle trust assumption, explicitly testnet only and not a real financial product)
- [ ] Short written audit-style report covering everything found in Phase 4
- [ ] Demo video, two to three minutes
- [ ] Stretch: submit to a CodeHawks First Flight or similar contest, the one part of this build that gets graded by someone other than the two of us

## Obstacles and how we're getting around them

**Fixed-point CDF precision.** Hand-rolling exp and ln in Solidity is a real source of bugs. Use PRBMath, it's audited and already used in production DeFi rather than something either of us writes from scratch. State the approximation's known error bound in the docs instead of implying exact pricing.

**Oracle manipulation at the settlement instant.** A single spot read at expiry is the classic attack surface here. Add the staleness check, consider snapshotting the settlement price slightly ahead of the exact expiry block rather than reading it in the same transaction as the trigger, and write an actual exploit test attempting to game it before assuming the mitigation holds.

**Unbounded gas from the volatility calculation.** Don't loop over the price window every time volatility is needed. Maintain the accumulator and update it incrementally on each snapshot.

**Two people in the same Solidity codebase.** Interfaces first, implementation second, decided on day one, so the two hardest pieces (pricing engine, vault) can be built in parallel against a shared interface instead of serially.

**Scope creep.** The MVP is one asset (WETH), one strike selection rule (fixed delta target), weekly epochs, testnet only. Multi-asset support, dynamic delta targeting, and mainnet deployment are stretch goals, not requirements. Decide this now so neither of you quietly expands scope two weeks in.

**"Isn't this just Dopex."** Say explicitly in the README what's different. Dopex's SSOVs exist and work, ours computes its own on-chain Black-Scholes pricing rather than depending on an external mechanism, and that's the part worth defending under questioning, not the vault shell around it.

## Suggested split (adjust to actual strengths)
- **Person A**: PricingEngine, the math, the fuzz tests against reference values, the security pass on that contract specifically.
- **Person B**: OptionsVault epoch mechanics, oracle and keeper integration, frontend, CI.
- Both: interface design on day one, Phase 4 security pass together, README and report together.

## What "top tier" actually means here

Not a working demo. An artifact that survives someone else reading the code closely. That means real fixed-point math with a stated error bound, a documented security pass with actual findings rather than a clean Slither run and nothing else, invariant tests run at real scale, and a README that's honest about what's a testnet toy and what's genuinely solid engineering. The pricing engine being correct and defensible under questioning matters more than any additional feature either of you is tempted to add.
