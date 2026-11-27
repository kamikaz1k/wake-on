// What each person used, per day, from the worker's KV: calls, the voice model's billed minutes,
// tokens (backend lookups, memory summaries) and the app build they last used, then each
// person's latest build. Run from server/: node scripts/usage.mjs [days]
// (default 7). Totals start 2026-11-24; seconds and lookup tokens are reported by the app at
// hang-up, so a call that ended without reaching the server is missing from them.
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";

const days = Number(process.argv[2] || 7);
const ns = readFileSync("wrangler.toml", "utf8").match(/binding = "USAGE"[\s\S]*?id = "([0-9a-f]+)"/)[1];
const wrangler = (...args) => {
  const r = spawnSync("npx", ["wrangler", "kv", ...args, "--namespace-id", ns, "--remote"], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stdout;
};

const since = new Date(Date.now() - (days - 1) * 86400_000).toISOString().slice(0, 10);
const keys = JSON.parse(wrangler("key", "list", "--prefix", "stats:")).map((k) => k.name)
  .filter((k) => k.split(":")[1] >= since).sort();
const k = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(1)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : String(n || 0));
const rows = [["day", "name", "calls", "voice min", "lookup in (cached)", "lookup out", "summaries", "summary in/out", "build"]];
const latest = {};
const total = {};
for (const key of keys) {
  const [, day, name] = key.split(":");
  const s = JSON.parse(wrangler("key", "get", key));
  for (const [f, v] of Object.entries(s)) if (typeof v === "number") total[f] = (total[f] || 0) + v;
  if (s.build) latest[name] = { day, build: s.build };
  rows.push([day, name, String(s.calls || 0), ((s.seconds || 0) / 60).toFixed(1),
    `${k(s.input_tokens)} (${k(s.cached_tokens)})`, k(s.output_tokens), String(s.summaries || 0),
    `${k(s.summary_input_tokens)}/${k(s.summary_output_tokens)}`, s.build || ""]);
}
const t = total;
rows.push(["total", "", String(t.calls || 0), ((t.seconds || 0) / 60).toFixed(1),
  `${k(t.input_tokens)} (${k(t.cached_tokens)})`, k(t.output_tokens), String(t.summaries || 0),
  `${k(t.summary_input_tokens)}/${k(t.summary_output_tokens)}`, ""]);
const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => r[i].length)));
for (const r of rows) console.log(r.map((c, i) => c.padEnd(widths[i])).join("  "));

// Keys are sorted by day, so the last build seen per person is the newest. Builds before
// 2026-11-27 don't send one.
console.log("\nLatest build per person (last day seen)");
for (const [name, { day, build }] of Object.entries(latest).sort()) console.log(`  ${name.padEnd(12)}  ${build}  (${day})`);
