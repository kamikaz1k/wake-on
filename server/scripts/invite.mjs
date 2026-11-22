// Invite codes and their signing keys. Run from server/ (scripts/invite.sh calls this).
//
//   add NAME          prints a code for NAME, signed with the newest key
//   revoke NAME       turns NAME's code off (within seconds, no deploy)
//   keys new          adds a signing key; new codes use it, older codes keep working
//   keys retire ID    removes a key: every code signed with it stops working
//                     (friends see "expired, ask for a new code")
//   list              key ids and revoked names (never the secrets)
//
// The signing keys and the revoked list live in server/.env (git-ignored) and are copied to
// the worker's encrypted secrets, INVITE_KEYS and REVOKED. Secrets are never printed.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";
import { sign } from "../src/index.js";

const ENV = ".env";

function readEnv() {
  const lines = existsSync(ENV) ? readFileSync(ENV, "utf8").split("\n") : [];
  const get = (name) => {
    const line = lines.find((item) => item.startsWith(`${name}=`));
    return line ? line.slice(name.length + 1).replace(/^'(.*)'$/, "$1") : "";
  };
  const set = (name, value) => {
    const entry = `${name}='${value}'`;
    const index = lines.findIndex((item) => item.startsWith(`${name}=`));
    if (index >= 0) lines[index] = entry;
    else lines.splice(lines.length && lines[lines.length - 1] === "" ? lines.length - 1 : lines.length, 0, entry);
    writeFileSync(ENV, lines.join("\n").replace(/\n?$/, "\n"), { mode: 0o600 });
  };
  return { get, set };
}

function push(name, value) {
  const result = spawnSync("npx", ["wrangler", "secret", "put", name], { input: value, stdio: ["pipe", "ignore", "inherit"] });
  if (result.status !== 0) throw new Error(`Couldn't update the worker's ${name}.`);
}

const env = readEnv();
const keys = JSON.parse(env.get("INVITE_KEYS") || "{}");
const revoked = env.get("REVOKED").split(",").map((item) => item.trim()).filter(Boolean);
const ids = Object.keys(keys).map(Number).sort((a, b) => a - b);
const cleanName = (name) => String(name || "").toLowerCase().replace(/[^a-z0-9]/g, "");
const [command, arg, arg2] = process.argv.slice(2);

if (command === "add") {
  const name = cleanName(arg);
  if (!name) throw new Error("usage: add NAME (letters and digits)");
  if (revoked.includes(name)) throw new Error(`${name}'s code was revoked; pick another name, like ${name}2.`);
  if (!ids.length) throw new Error("No signing key yet: run `keys new` first.");
  const id = String(ids[ids.length - 1]);
  console.log(`Invite code for ${name}: ${name}-${id}-${await sign(keys[id], id, name)}`);
} else if (command === "revoke") {
  const name = cleanName(arg);
  if (!name) throw new Error("usage: revoke NAME");
  if (!revoked.includes(name)) revoked.push(name);
  env.set("REVOKED", revoked.join(","));
  push("REVOKED", revoked.join(","));
  console.log(`Revoked ${name}. Their calls stop working now.`);
} else if (command === "keys" && arg === "new") {
  const id = String((ids[ids.length - 1] || 0) + 1);
  keys[id] = randomBytes(32).toString("base64url");
  env.set("INVITE_KEYS", JSON.stringify(keys));
  push("INVITE_KEYS", JSON.stringify(keys));
  console.log(`Signing key ${id} added; new codes use it.${ids.length ? " Codes from older keys still work." : ""}`);
} else if (command === "keys" && arg === "retire") {
  if (!keys[arg2]) throw new Error(`No key ${arg2}. Keys: ${ids.join(", ") || "none"}`);
  delete keys[arg2];
  env.set("INVITE_KEYS", JSON.stringify(keys));
  push("INVITE_KEYS", JSON.stringify(keys));
  console.log(`Key ${arg2} retired: its codes now say "expired". Send those friends new codes.`);
} else if (command === "list") {
  console.log(`Signing keys: ${ids.join(", ") || "none"} (new codes use ${ids[ids.length - 1] ?? "none"})`);
  console.log(`Revoked: ${revoked.join(", ") || "none"}`);
} else {
  console.log("usage: scripts/invite.sh add NAME | revoke NAME | keys new | keys retire ID | list");
  process.exit(1);
}
