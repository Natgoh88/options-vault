// Local development harness. Deploys the full system to a local anvil chain with a mock Chainlink
// feed, then drives complete epochs through the real VaultKeeper so the UI has realistic state to
// render: settled OTM / ITM epochs and a live one.
//
//   anvil --port 8545 --chain-id 31337                              (terminal 1)
//   node scripts/dev-seed.mjs [--epochs 3] [--until active|writing|idle]   (terminal 2)
//   node scripts/dev-seed.mjs --attach --until idle|writing|active  (later: step an existing chain)
//   add --nobuy to leave the writing window empty for manual purchases from the UI
//   VITE_CHAIN_ID=31337 npm run dev
//
// Uses anvil's public, well-known test keys. Never point this at a real network.
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { createPublicClient, createTestClient, createWalletClient, http, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

const RPC = process.env.RPC ?? "http://127.0.0.1:8545";
const root = path.resolve(import.meta.dirname, "../..");

// accepts `--key=value`, `--key value` and bare `--flag`
const args = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  if (!argv[i].startsWith("--")) continue;
  const [k, inline] = argv[i].slice(2).split("=");
  if (inline !== undefined) args[k] = inline;
  else if (argv[i + 1] !== undefined && !argv[i + 1].startsWith("--")) args[k] = argv[++i];
  else args[k] = "true";
}
const ATTACH = args.attach === "true";
const UNTIL = args.until ?? "active";
const EPOCHS = Number(args.epochs ?? 3);
const STEP = Number(args.step ?? 900); // seconds per simulated tick (>= the engine sample interval)
const STATE_NAMES = ["idle", "writing", "active", "settling"];

// anvil's default accounts (public test keys)
const KEYS = {
  deployer: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  alice: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  bob: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  buyer: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
};

const pub = createPublicClient({ chain: foundry, transport: http(RPC) });
const test = createTestClient({ chain: foundry, mode: "anvil", transport: http(RPC) });
const wallets = Object.fromEntries(
  Object.entries(KEYS).map(([name, k]) => {
    const account = privateKeyToAccount(k);
    return [name, createWalletClient({ account, chain: foundry, transport: http(RPC) })];
  }),
);

const artifact = (file, name) => {
  const j = JSON.parse(fs.readFileSync(path.join(root, "out", file, `${name}.json`), "utf8"));
  return { abi: j.abi, bytecode: j.bytecode.object };
};

const send = async (w, address, abi, functionName, fnArgs = []) => {
  const hash = await w.writeContract({ address, abi, functionName, args: fnArgs });
  return pub.waitForTransactionReceipt({ hash });
};
const read = (address, abi, functionName, fnArgs = []) =>
  pub.readContract({ address, abi, functionName, args: fnArgs });

const erc20 = artifact("Mocks.sol", "MockERC20");
const agg = artifact("Mocks.sol", "MockAggregator");
const vaultA = artifact("OptionsVault.sol", "OptionsVault");
const keeperA = artifact("VaultKeeper.sol", "VaultKeeper");
const usdcA = artifact("TestUSDC.sol", "TestUSDC");

async function deployMock(file, name, ctorArgs) {
  const { abi, bytecode } = artifact(file, name);
  const hash = await wallets.deployer.deployContract({ abi, bytecode, args: ctorArgs });
  const r = await pub.waitForTransactionReceipt({ hash });
  return { address: r.contractAddress, abi };
}

let dep;
let feedAddr;
let wethAddr;
let price = 2675;

const pushFeed = (p) =>
  send(wallets.deployer, feedAddr, agg.abi, "push", [BigInt(Math.round(p * 1e8))]);

if (ATTACH) {
  dep = JSON.parse(fs.readFileSync(path.join(root, "deployments", "31337.json"), "utf8"));
  feedAddr = dep.feed;
  wethAddr = dep.weth;
  const [, answer] = await read(feedAddr, agg.abi, "latestRoundData");
  price = Number(answer) / 1e8;
  console.log(`attached to vault ${dep.vault}, ETH ${price.toFixed(2)}`);
} else {
  console.log("deploying mocks (WETH, ETH/USD feed)");
  const weth = await deployMock("Mocks.sol", "MockWETH", []); // WETH9-compatible: wrap works
  const feed = await deployMock("Mocks.sol", "MockAggregator", [8]);
  wethAddr = weth.address;
  feedAddr = feed.address;
  await pushFeed(price);

  console.log("deploying system via forge script");
  const env = {
    ...process.env,
    PROFILE: "demo",
    WETH: wethAddr,
    FEED: feedAddr,
    PATH: `${process.env.PATH};${process.env.USERPROFILE}\\.foundry\\bin`,
  };
  execFileSync(
    "forge",
    ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast", "--private-key", KEYS.deployer, "--silent"],
    { cwd: root, env, stdio: ["ignore", "inherit", "inherit"] },
  );
  dep = JSON.parse(fs.readFileSync(path.join(root, "deployments", "31337.json"), "utf8"));

  // the dev "Automation forwarder" is the deployer, so this script can drive the keeper
  await send(wallets.deployer, dep.keeper, keeperA.abi, "setForwarder", [wallets.deployer.account.address]);

  console.log("funding accounts and depositing");
  await send(wallets.alice, wethAddr, erc20.abi, "mint", [wallets.alice.account.address, parseEther("18")]);
  await send(wallets.bob, wethAddr, erc20.abi, "mint", [wallets.bob.account.address, parseEther("8")]);
  for (const [who, amt] of [["alice", "12"], ["bob", "5"]]) {
    const w = wallets[who];
    await send(w, wethAddr, erc20.abi, "approve", [dep.vault, parseEther(amt)]);
    await send(w, dep.vault, vaultA.abi, "deposit", [parseEther(amt), w.account.address]);
  }
}

// ---------------------------------------------------------------- helpers
let seed = ATTACH ? Date.now() % 1000 : 42;
const rand = () => {
  seed = (seed * 1664525 + 1013904223) % 4294967296;
  return seed / 4294967296;
};
const gauss = () => Math.sqrt(-2 * Math.log(rand() + 1e-12)) * Math.cos(2 * Math.PI * rand());

const advance = async (s) => {
  await test.increaseTime({ seconds: s });
  await test.mine({ blocks: 1 });
};

async function upkeep() {
  for (let i = 0; i < 8; i++) {
    const [need, data] = await read(dep.keeper, keeperA.abi, "checkUpkeep", ["0x"]);
    if (!need) return;
    await send(wallets.deployer, dep.keeper, keeperA.abi, "performUpkeep", [data]);
  }
}

const vaultRead = (fn, a) => read(dep.vault, vaultA.abi, fn, a);
const state = async () => Number(await vaultRead("state"));
const epoch = async () => Number(await vaultRead("currentEpoch"));
const epochData = (id) => vaultRead("epochData", [BigInt(id)]);

async function buyOptions(fraction) {
  const id = await epoch();
  const e = await epochData(id);
  const amount = (e.collateralLocked * BigInt(Math.round(fraction * 100))) / 100n;
  const cost = (amount * e.premiumPerOption) / 10n ** 18n + 10n;
  const w = wallets.buyer;
  const bal = await read(dep.usdc, usdcA.abi, "balanceOf", [w.account.address]);
  if (bal < cost) {
    try {
      await send(w, dep.usdc, usdcA.abi, "faucet");
    } catch {
      /* cooldown */
    }
  }
  await send(w, dep.usdc, usdcA.abi, "approve", [dep.vault, cost]);
  await send(w, dep.vault, vaultA.abi, "buyOptions", [amount]);
}

// ---------------------------------------------------------------- drive
let settled = 0;
let bought = -1; // epoch id we already bought into
let forced = null; // { epoch, target }: price override to create an in-the-money finish
let steps = 0;

if (ATTACH) {
  // already-running epoch: don't try to buy into it, and treat earlier ones as settled
  bought = (await state()) >= 1 ? await epoch() : -1;
  settled = Math.max(0, (await epoch()) - ((await state()) === 0 ? 0 : 1));
}

console.log("driving epochs");
while (steps++ < 4000) {
  await advance(STEP);
  const s = await state();
  const id = await epoch();

  if (forced && forced.epoch === id && s === 2) {
    price += (forced.target - price) * 0.25; // drift to the forced in-the-money level
  } else {
    price *= Math.exp(0.003 * gauss());
  }
  await pushFeed(price);
  await upkeep();

  const s2 = await state();
  const id2 = await epoch();

  if (s2 === 1 && bought !== id2 && args.nobuy !== "true") {
    // sell most of the epoch, leaving some unsold so the "sold" bar is not full
    await buyOptions(id2 === 3 ? 0.55 : 0.85);
    bought = id2;
    if (id2 === 2 && !ATTACH) {
      const e = await epochData(2);
      forced = { epoch: 2, target: (Number(e.strike) / 1e18) * 1.09 };
    }
    await upkeep();
  }

  const cur = await epoch();
  if (cur > 0 && (await epochData(cur)).settled && cur > settled) settled = cur;

  const st = await state();
  if (ATTACH) {
    if (steps > 1 && STATE_NAMES[st] === UNTIL) break;
    continue;
  }
  if (settled >= EPOCHS) {
    if (UNTIL === "idle" && st === 0) break;
    if (UNTIL === "writing" && st === 1) break;
    if (UNTIL === "active" && st === 2 && cur === EPOCHS + 1) {
      // sit a few steps into the live epoch so the countdown and Greeks are mid-flight
      for (let k = 0; k < 6; k++) {
        await advance(STEP);
        price *= Math.exp(0.003 * gauss());
        await pushFeed(price);
        await upkeep();
      }
      break;
    }
  }
}

console.log(`\nready: epoch ${await epoch()} ${STATE_NAMES[await state()]}; ETH ${price.toFixed(2)}`);
console.log(`vault ${dep.vault}`);
