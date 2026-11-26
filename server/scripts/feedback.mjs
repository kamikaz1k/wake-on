// Feedback people asked Pixie to send, newest first, from the worker's KV.
// Run from server/: node scripts/feedback.mjs [days] (default 14). Kept a year.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const days = Number(process.argv[2] || 14);
const ns = readFileSync("wrangler.toml", "utf8").match(/binding = "USAGE"[\s\S]*?id = "([0-9a-f]+)"/)[1];
const wrangler = (...args) => {
  const r = spawnSync("npx", ["wrangler", "kv", ...args, "--namespace-id", ns, "--remote"], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stdout;
};

const since = new Date(Date.now() - (days - 1) * 86400_000).toISOString().slice(0, 10);
const keys = JSON.parse(wrangler("key", "list", "--prefix", "feedback:")).map((k) => k.name)
  .filter((k) => k.slice("feedback:".length, "feedback:".length + 10) >= since).sort().reverse();
if (!keys.length) console.log(`No feedback in the last ${days} days.`);
for (const key of keys) {
  const f = JSON.parse(wrangler("key", "get", key));
  console.log(`${f.at.slice(0, 16).replace("T", " ")} UTC  ${f.name}  build ${f.app || "?"}`);
  console.log(`  ${f.feedback}`);
  if (f.context) console.log(`  Pixie's note: ${f.context}`);
  console.log();
}
