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
//   USAGE                KV namespace: invite codes and daily counters
//   DAILY_CALLS          calls per code per UTC day (default 40)
//   GLOBAL_DAILY_CALLS   calls per UTC day across everyone (default 300)
//   ALLOWED_MODELS       comma-separated voice models (default gpt-live-1.1,gpt-live-1)
//   ALLOWED_BACKEND_MODELS comma-separated delegation models (default gpt-5.6-terra)
//
// Invite codes live in KV as `code:<sha256 of the code>` → {"name": "Alex"}; see
// scripts/invite.sh. Only the hash is stored, so the KV contents don't reveal codes.

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
  if (url.pathname !== "/v1/live/sessions") return error(404, "not_found", "Unknown path.");
  if (request.method !== "POST") return error(405, "method_not_allowed", "Use POST.");

  // Each step's time goes back in a Server-Timing header, so the app's log shows where the
  // server's share of a call's set-up went (the code itself is never logged).
  const timing = new Timing();
  const code = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!code) return error(401, "missing_code", "Enter your invite code in Settings.");
  const codeHash = await sha256(code);
  const invite = await timing.step("code", env.USAGE.get(`code:${codeHash}`, "json"));
  if (!invite) return error(401, "invalid_code", "That invite code isn't valid.");

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
  const codeKey = `count:${day}:${codeHash}`;
  const allKey = `count:${day}:all`;
  const [codeCount, allCount] = await timing.step("limits", Promise.all([count(env, codeKey), count(env, allKey)]));
  if (codeCount >= perCode) return error(429, "daily_limit", "You've reached today's call limit.");
  if (allCount >= overall) return error(429, "global_limit", "Lobby is out of calls for today.");

  // Recordings stay off whatever the client asks.
  body.session.store = false;
  const response = await timing.step("openai", upstream(OPENAI_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
      // Lets OpenAI tell users apart for abuse handling without learning who they are.
      "OpenAI-Safety-Identifier": codeHash.slice(0, 32),
    },
    body: JSON.stringify(body),
  }));
  // Count only calls OpenAI accepted (a failed setup costs nothing).
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
  for (const name of ["x-request-id", "openai-processing-ms"]) {
    const value = response.headers.get(name);
    if (value) headers.set(name, value);
  }
  const colo = request.cf && request.cf.colo;
  headers.set("Server-Timing", timing.header(colo));
  console.log(JSON.stringify({ status: response.status, colo, ms: timing.steps }));
  return new Response(response.body, { status: response.status, headers });
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
