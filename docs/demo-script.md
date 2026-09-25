# Demo video script (2 to 3 minutes)

The goal is not a feature tour. It is to show one claim and prove it: **the contract prices its own
options, and you can check the math.** Record at 1440×900, browser zoom 100%, dark OS theme.

Before recording: deploy with `PROFILE=demo`, deposit from wallet A, and have the keeper running
(`script/keeper-once.sh --loop`) until an epoch is in **Writing**. Keep wallet B funded with
testnet ETH and with test USDC from the in-app faucet.

---

**0:00 to 0:15. The claim** *(app, top of the page)*
> "This is a covered-call vault on Arbitrum. The interesting part isn't the vault; it's that the
> contract prices every option itself, with Black-Scholes in fixed-point Solidity, from a
> volatility estimate it keeps on-chain. No market maker, no off-chain quote."

**0:15 to 0:45. Where the number comes from** *(Epoch panel, then Greeks panel)*
- Point at strike and premium: "Chosen at epoch start: the strike with a 30 delta, priced from
  Chainlink spot and the contract's own realized vol."
- Scroll to Greeks: "These aren't computed in the browser. They come from
  `PricingEngine.callGreeks`, the same code that set the premium." Point at *Fair value now*
  against *Premium charged*: "The 2% gap is a deliberate safety margin."

**0:45 to 1:05. What a depositor gets** *(payoff chart, hover across it)*
> "Per WETH: you keep the premium below the strike and give up the upside above it. Here's the
> breakeven."

**1:05 to 1:40. Buy an option, live** *(switch to wallet B, Options tab)*
- Enter 0.5, click *Approve USDC*, then *Buy options*. Show the toast and the sold % bar moving.
> "Price and strike were fixed at epoch start, and purchases revert if spot has moved more than
> the allowed band, so nobody can pick off a stale quote."

**1:40 to 2:10. Settlement can't be gamed** *(open `test/Stack.t.sol` in the editor, or read the
README section)*
> "At expiry the settlement price isn't read at trigger time. It's the last Chainlink round at or
> before expiry, so there's exactly one valid answer. We have exploit tests that try to
> manipulate the feed after expiry and cherry-pick an earlier spike; both fail."

**2:10 to 2:40. Why you can trust the math** *(terminal: `forge test`, then the security report)*
- Show the test run finishing. "126 tests. The pricing is checked against 400 reference cases
  from Python's exact normal CDF, with tolerances derived from the approximation's stated error
  bound. Invariants run 50,000 times nightly."
- Scroll the security report's findings log: "Two audit passes; every real finding has an exploit
  test that fails without the fix."

**2:40 to 2:50. Close**
> "Testnet only, not audited by a third party, and the README lists every limitation we know of."

---

Recording tips: hide the bookmarks bar, close other tabs, turn off notifications. Keep the cursor
still while you talk. Cut anything where you wait for a transaction; show only the toast
changing to success.
