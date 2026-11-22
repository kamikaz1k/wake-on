// Wake On's call server: a Cloudflare Worker that holds the OpenAI key so the app doesn't.
//
// The app sends exactly what it would send OpenAI (POST /v1/live/sessions with the session
// config and the WebRTC offer), with an invite code instead of an API key. The worker checks
// the code, counts calls per code per day, checks the models, and forwards the request to
// OpenAI with the real key. The call's audio then flows straight between the phone and
// OpenAI; it never passes through here.
//
// Bindings (wrangler.toml / `wrangler secret put`):
//   OPENAI_API_KEY       secret, the project key
//   INVITE_KEYS          secret, JSON {"<key id>": "<signing secret>"}: codes signed with a
//                        listed key work; remove a key and its codes stop working
//   REVOKED              secret, comma-separated names whose codes are turned off
//   USAGE                KV namespace: daily counters only
//   DAILY_CALLS          calls per code per UTC day (default 40)
//   GLOBAL_DAILY_CALLS   calls per UTC day across everyone (default 300)
//   ALLOWED_MODELS       comma-separated voice models (default gpt-live-1.1,gpt-live-1)
//   ALLOWED_BACKEND_MODELS comma-separated delegation models (default gpt-5.6-terra)
//
// Invite codes are signed, so checking one needs no storage: `<name>-<key id>-<signature>`,
// e.g. `alex-1-7k2mq9xd4r8w`, where the signature is the first 60 bits of
// HMAC-SHA256(signing secret, "<key id>:<name>"). scripts/invite.mjs makes them. The daily
// counts are read while OpenAI sets up the call, so KV adds no time to it.

const OPENAI_URL = "https://api.openai.com/v1/live/sessions";
const MAX_BODY_BYTES = 256 * 1024;

export default {
  async fetch(request, env, ctx) {
    return handle(request, env, fetch, ctx);
  },
};

/** The whole worker, with `upstream` standing in for fetch and `ctx` for the Worker's
 * execution context (tests pass fakes). */
export async function handle(request, env, upstream, ctx = { waitUntil: () => {} }) {
  const url = new URL(request.url);
  // The app opens a connection ahead of a call with a HEAD request: answer it cheaply.
  if (request.method === "HEAD") return new Response(null, { status: 204 });
  if (url.pathname === "/health") return json(200, { ok: true });
  // The app checks a code before saving it: same answers as a call, but OpenAI isn't asked
  // and nothing is counted.
  if (url.pathname === "/v1/check" && request.method === "POST") {
    const code = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (!code) return error(401, "missing_code", PROBLEMS.invalid_code);
    const check = await checkCode(code, env);
    if (check.problem) return error(401, check.problem, PROBLEMS[check.problem]);
    return json(200, { ok: true, name: check.name });
  }
  if (url.pathname !== "/v1/live/sessions") return error(404, "not_found", "Unknown path.");
  if (request.method !== "POST") return error(405, "method_not_allowed", "Use POST.");

  // Each step's time goes back in a Server-Timing header, so the app's log shows where the
  // server's share of a call's set-up went (the code itself is never logged).
  const timing = new Timing();
  const code = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!code) return error(401, "missing_code", "Enter your invite code in Settings.");
  const check = await timing.step("code", checkCode(code, env));
  if (check.problem) return error(401, check.problem, PROBLEMS[check.problem]);
  const name = check.name;

  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return error(413, "too_large", "Request too large.");
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return error(400, "bad_json", "Request body isn't JSON.");
  }
  const problem = checkSession(body, env);
  if (problem) return error(400, "not_allowed", problem);

  const day = new Date().toISOString().slice(0, 10);
  const perCode = Number(env.DAILY_CALLS || 40);
  const overall = Number(env.GLOBAL_DAILY_CALLS || 300);
  const codeKey = `count:${day}:${name}`;
  const allKey = `count:${day}:all`;

  // Recordings stay off whatever the client asks.
  body.session.store = false;
  // OpenAI sets up the call while the counts are read; over the limit, the answer is held
  // back, so the phone can't connect and no audio is used.
  const safetyId = (await sha256(name)).slice(0, 32);
  const counts = timing.step("limits", Promise.all([count(env, codeKey), count(env, allKey)]));
  const [response, [codeCount, allCount]] = await Promise.all([
    timing.step("openai", upstream(OPENAI_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
        // Lets OpenAI tell users apart for abuse handling without learning who they are.
        "OpenAI-Safety-Identifier": safetyId,
      },
      body: JSON.stringify(body),
    })),
    counts,
  ]);
  if (codeCount >= perCode) return error(429, "daily_limit", "You've used today's calls.");
  if (allCount >= overall) return error(429, "global_limit", "Lobby is out of calls for today.");
  // The writes run after the reply is sent (they took 195-345 ms, all of it on the call's
  // set-up). Two calls at the same moment can then both pass the limit; that's acceptable.
  if (response.ok) {
    const ttl = { expirationTtl: 3 * 24 * 3600 };
    ctx.waitUntil(Promise.all([
      env.USAGE.put(codeKey, String(codeCount + 1), ttl),
      env.USAGE.put(allKey, String(allCount + 1), ttl),
    ]));
  }
  const headers = new Headers({ "Content-Type": response.headers.get("Content-Type") || "application/json" });
  for (const header of ["x-request-id", "openai-processing-ms"]) {
    const value = response.headers.get(header);
    if (value) headers.set(header, value);
  }
  const colo = request.cf && request.cf.colo;
  headers.set("Server-Timing", timing.header(colo));
  console.log(JSON.stringify({ status: response.status, colo, ms: timing.steps }));
  return new Response(response.body, { status: response.status, headers });
}

const PROBLEMS = {
  invalid_code: "That invite code isn't valid.",
  expired_code: "That invite code has expired.",
  revoked_code: "That invite code was turned off.",
};

/** Checks a signed invite code: {name} or {problem}. No storage is read. */
export async function checkCode(code, env) {
  const parts = code.toLowerCase().split("-");
  if (parts.length !== 3) return { problem: "invalid_code" };
  const [name, keyId, signature] = parts;
  let keys;
  try {
    keys = JSON.parse(env.INVITE_KEYS || "{}");
  } catch {
    keys = {};
  }
  if (!keys[keyId]) return { problem: /^\d+$/.test(keyId) ? "expired_code" : "invalid_code" };
  if (!sameText(signature, await sign(keys[keyId], keyId, name))) return { problem: "invalid_code" };
  const revoked = String(env.REVOKED || "").split(",").map((item) => item.trim().toLowerCase());
  if (revoked.includes(name)) return { problem: "revoked_code" };
  return { name };
}

/** A name's signature with one key: 12 base32 characters (60 bits). */
export async function sign(secret, keyId, name) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${keyId}:${name}`)));
  const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
  let bits = 0n;
  for (const byte of mac.slice(0, 8)) bits = (bits << 8n) | BigInt(byte);
  let out = "";
  for (let i = 0; i < 12; i++) out += alphabet[Number((bits >> BigInt(59 - i * 5)) & 31n)];
  return out;
}

/** Compares without stopping at the first difference. */
function sameText(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** Why this session config isn't allowed, or null. Keeps the key to Wake On's own calls. */
export function checkSession(body, env) {
  const session = body && body.session;
  if (!session || typeof session !== "object") return "Missing session.";
  if (!body.transport || body.transport.type !== "webrtc") return "Only WebRTC calls are allowed.";
  const models = list(env.ALLOWED_MODELS, "gpt-live-1.1,gpt-live-1");
  if (!models.includes(session.model)) return `Model ${session.model} isn't allowed.`;
  const delegation = session.delegation;
  if (delegation) {
    const backend = delegation.responses && delegation.responses.model;
    const backends = list(env.ALLOWED_BACKEND_MODELS, "gpt-5.6-terra");
    if (delegation.type !== "responses" || !backends.includes(backend)) {
      return `Backend model ${backend} isn't allowed.`;
    }
  }
  return null;
}

/** Durations of the server's own steps, in ms. (Workers' clock only moves across I/O, which
 * is exactly what these steps are.) */
export class Timing {
  constructor() {
    this.start = Date.now();
    this.steps = {};
  }
  async step(name, promise) {
    const begin = Date.now();
    try {
      return await promise;
    } finally {
      this.steps[name] = Date.now() - begin;
    }
  }
  header(colo) {
    const parts = Object.entries(this.steps).map(([name, ms]) => `${name};dur=${ms}`);
    parts.push(`total;dur=${Date.now() - this.start}`);
    if (colo) parts.push(`colo;desc=${colo}`);
    return parts.join(",");
  }
}

async function count(env, key) {
  return Number((await env.USAGE.get(key)) || 0);
}

function list(value, fallback) {
  return String(value || fallback).split(",").map((item) => item.trim()).filter(Boolean);
}

export async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(status, value) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}

/** Errors in OpenAI's shape, so the app shows the message the same way. */
function error(status, code, message) {
  return json(status, { error: { code, message } });
}
