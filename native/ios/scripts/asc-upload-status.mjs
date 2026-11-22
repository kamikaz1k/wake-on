// Waits for App Store Connect to finish processing an uploaded build and prints its errors.
// node scripts/asc-upload-status.mjs <bundle id> <build number> [minutes]
// Exit 0 when processing succeeded, 1 when it failed, 2 on timeout. Signs its API request
// with the key named in ~/.appstoreconnect/deploy.env; never prints the key.
import fs from "node:fs";
import os from "node:os";
import crypto from "node:crypto";

const [bundleId, build, minutes = "20"] = process.argv.slice(2);
const env = Object.fromEntries(
  fs.readFileSync(`${os.homedir()}/.appstoreconnect/deploy.env`, "utf8").split("\n")
    .filter((l) => l.includes("="))
    .map((l) => { const i = l.indexOf("="); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^"|"$/g, "")]; }));
const keyPath = env.ASC_KEY_PATH.replace(/^(~|\$HOME)/, os.homedir());

function token() {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const body = `${b64({ alg: "ES256", kid: env.ASC_KEY_ID, typ: "JWT" })}.${b64({ iss: env.ASC_ISSUER_ID, iat: now, exp: now + 600, aud: "appstoreconnect-v1" })}`;
  const sig = crypto.sign("sha256", Buffer.from(body), { key: fs.readFileSync(keyPath), dsaEncoding: "ieee-p1363" });
  return `${body}.${sig.toString("base64url")}`;
}
async function get(path) {
  const r = await fetch(`https://api.appstoreconnect.apple.com${path}`, { headers: { Authorization: `Bearer ${token()}` } });
  if (!r.ok) throw new Error(`${r.status} ${path}`);
  return (await r.json()).data;
}

const [app] = await get(`/v1/apps?filter[bundleId]=${bundleId}`);
if (!app) { console.log(`No App Store Connect app for ${bundleId}`); process.exit(1); }
const deadline = Date.now() + Number(minutes) * 60_000;
while (Date.now() < deadline) {
  const uploads = await get(`/v1/apps/${app.id}/buildUploads?limit=10`);
  const upload = uploads.find((u) => u.attributes.cfBundleVersion === build);
  const state = upload?.attributes.state;
  if (state?.state === "FAILED") {
    console.log(`Build ${build} failed processing:`);
    for (const e of state.errors ?? []) console.log(`  ${e.code}: ${e.description}`);
    process.exit(1);
  }
  if (state?.state === "COMPLETE") {
    for (const w of state.warnings ?? []) console.log(`  warning ${w.code}: ${w.description}`);
    console.log(`Build ${build} processed. It's in TestFlight.`);
    process.exit(0);
  }
  await new Promise((resolve) => setTimeout(resolve, 30_000));
}
console.log(`Build ${build} still processing after ${minutes} min; check TestFlight later.`);
process.exit(2);
