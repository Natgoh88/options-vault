// Captures marketing/README screenshots of the running app with headless Edge/Chrome over the
// DevTools protocol (no extra dependencies). Needs the dev server running on :5173.
//
//   node scripts/screenshots.mjs [outDir]
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const OUT = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, "../../docs/images"));
const URL_ = process.env.APP_URL ?? "http://127.0.0.1:5173/";
const BROWSER =
  process.env.BROWSER ??
  ["C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe", "C:/Program Files/Google/Chrome/Application/chrome.exe"].find(
    (p) => fs.existsSync(p),
  );
const PORT = 9333;
const W = 1440;
const SCALE = 2;

fs.mkdirSync(OUT, { recursive: true });
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "ov-shots-"));
const proc = spawn(BROWSER, [
  "--headless=new",
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  "--hide-scrollbars",
  "--no-first-run",
  "--force-color-profile=srgb",
  "about:blank",
]);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function target() {
  for (let i = 0; i < 50; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      const page = list.find((t) => t.type === "page");
      if (page) return page.webSocketDebuggerUrl;
    } catch {}
    await sleep(200);
  }
  throw new Error("browser did not start");
}

const ws = new WebSocket(await target());
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let id = 0;
const pending = new Map();
ws.addEventListener("message", (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  }
});
const send = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const i = ++id;
    pending.set(i, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)));
    ws.send(JSON.stringify({ id: i, method, params }));
  });
const evaluate = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true })).result.value;

await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", { width: W, height: 900, deviceScaleFactor: SCALE, mobile: false });
await send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
await send("Page.navigate", { url: URL_ });
// wait for live chain data (the Greeks panel is the last thing to fill in)
for (let i = 0; i < 60; i++) {
  if (await evaluate(`document.body.innerText.includes("DELTA") && !document.body.innerText.includes("Loading")`)) break;
  await sleep(500);
}
await evaluate(`document.fonts.ready.then(() => true)`);
await sleep(1200);

async function shot(name, clipExpr, pad = 18) {
  const r = await evaluate(`(() => { const r = (${clipExpr}); return { x: r.x + scrollX, y: r.y + scrollY, w: r.width, h: r.height }; })()`);
  const clip = { x: Math.max(0, r.x - pad), y: Math.max(0, r.y - pad), width: r.w + pad * 2, height: r.h + pad * 2, scale: 1 };
  const { data } = await send("Page.captureScreenshot", { format: "png", clip, captureBeyondViewport: true });
  const file = path.join(OUT, `${name}.png`);
  fs.writeFileSync(file, Buffer.from(data, "base64"));
  console.log(`${name}.png  ${Math.round(clip.width * SCALE)}x${Math.round(clip.height * SCALE)}`);
}

const panel = (title) =>
  `[...document.querySelectorAll(".panel")].find((p) => p.querySelector("h2")?.textContent.trim().startsWith(${JSON.stringify(title)})).getBoundingClientRect()`;

// 1. hero: header through the first row of panels (what someone sees when the page opens)
await shot(
  "01-overview",
  `(() => { const a = document.querySelector(".header").getBoundingClientRect(); const b = document.querySelector(".grid").getBoundingClientRect(); const e = document.querySelector(".stack > .panel").getBoundingClientRect(); return new DOMRect(0, a.y, ${W}, e.bottom + 14 - a.y); })()`,
  0,
);
await shot("02-payoff-chart", panel("Payoff at expiry"));
await shot("03-greeks", panel("Greeks"));
await shot("04-epoch-history", panel("Epoch history"));

ws.close();
proc.kill();
