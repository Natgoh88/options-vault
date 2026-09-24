# Deploying to Arbitrum Sepolia

Everything here is testnet. Use a **new throwaway wallet** for deployment. Never import a key that
has ever held real funds.

Verified on-chain before writing the script (chain 421614):

| | Address | Check |
|---|---|---|
| WETH | `0x980B62Da83eFf3D4576C647993b0c1D7faf17c73` | `symbol() == "WETH"` |
| Chainlink ETH / USD | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` | `description() == "ETH / USD"`, 8 decimals, updates about every 2 minutes |

USDC is a `TestUSDC` deployed by the script (public faucet, 10,000 per address per hour) so anyone
reviewing the deployment can buy options. The Arbitrum sequencer-uptime feed is not used on Sepolia.

## 1. One-time wallet setup

```bash
cast wallet import deployer --interactive
```

Paste the throwaway wallet's private key when prompted and choose a password. It is stored
encrypted in `~/.foundry/keystores/`; nothing goes in `.env`.

Fund the address with about 0.005 Arbitrum Sepolia ETH (a dry run estimated 0.0012 ETH). Any
Arbitrum Sepolia faucet works; bridging Sepolia ETH via bridge.arbitrum.io also works.

## 2. Deploy

Dry run first (sends nothing, uses a fork of the real testnet):

```bash
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --sender <your address>
```

Then broadcast:

```bash
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --account deployer --broadcast
```

`PROFILE=demo` (default) compresses time so a full epoch takes about 7 hours; `PROFILE=weekly` uses
the production cadence (7-day epochs, 1-day exit window). The script writes
`deployments/421614.json`.

### Verify the source

Keyless, via Sourcify:

```bash
forge verify-contract <address> src/OptionsVault.sol:OptionsVault \
  --chain 421614 --verifier sourcify
```

Or on Arbiscan with a free API key: add `--verifier etherscan --etherscan-api-key <key>`. Do this
for the vault, engine, resolver, option token, keeper and TestUSDC (constructor arguments are in
`broadcast/Deploy.s.sol/421614/run-latest.json`).

## 3. Automation (the keeper)

The epoch lifecycle needs something to call the keeper contract. Two options:

**A. Chainlink Automation (intended)**
1. Get Arbitrum Sepolia LINK from faucets.chain.link.
2. automation.chain.link, Register new upkeep, Custom logic, target = the `keeper` address.
3. Gas limit 3,000,000; fund with about 5 LINK.
4. Copy the upkeep's **forwarder address**, then:
   ```bash
   cast send <keeper> "setForwarder(address)" <forwarder> --rpc-url arbitrum_sepolia --account deployer
   ```

**B. Run it yourself (no LINK, good for demos)**
```bash
cast send <keeper> "setForwarder(address)" <your address> --rpc-url arbitrum_sepolia --account deployer
ACCOUNT=deployer ./script/keeper-once.sh --loop
```

The first epoch starts about an hour after deployment, once the engine has 6 snapshots at 10-minute
spacing, and at least one deposit exists.

## 4. Frontend

```bash
forge build
cd frontend && npm install && npm run sync     # copies ABIs and deployments/421614.json into src/
npm run dev                                    # http://localhost:5173
```

Commit `deployments/421614.json` and `frontend/src/deployments.json` so Vercel can build without
Foundry. Then either:

- **Vercel dashboard:** New Project, import the GitHub repo, set **Root Directory** to `frontend`
  (framework Vite is auto-detected; `vercel.json` sets the security headers). No environment
  variables are needed.
- **CLI:** `cd frontend && npx vercel login && npx vercel --prod`.

## Local development

`frontend/scripts/dev-seed.mjs` deploys the system to a local anvil chain with a mock Chainlink feed
and drives several full epochs through the real keeper (OTM, ITM and live), so the UI can be built
and screenshotted with realistic data:

```bash
anvil --port 8545 --chain-id 31337
cd frontend && node scripts/dev-seed.mjs            # deploys, seeds, drives 3 epochs
node scripts/dev-seed.mjs --attach --until idle      # later: step the chain to idle|writing|active
# frontend/.env.local:  VITE_CHAIN_ID=31337   VITE_DEV_PRIVATE_KEY=<anvil test key>
npm run sync && npm run dev
```

The dev signer only works on chain 31337; on any other chain the variable is ignored.
