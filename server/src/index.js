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
  async fetch(request, env) {
    return handle(request, env, fetch);
  },
};

/** The whole worker, with `upstream` standing in for fetch (tests pass a fake). */
export async function handle(request, env, upstream) {
  const url = new URL(request.url);
  // The app opens a connection ahead of a call with a HEAD request: answer it cheaply.
  if (request.method === "HEAD") return new Response(null, { status: 204 });
  if (url.pathname === "/health") return json(200, { ok: true });
  if (url.pathname !== "/v1/live/sessions") return error(404, "not_found", "Unknown path.");
  if (request.method !== "POST") return error(405, "method_not_allowed", "Use POST.");

  const code = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!code) return error(401, "missing_code", "Enter your invite code in Settings.");
  const codeHash = await sha256(code);
  const invite = await env.USAGE.get(`code:${codeHash}`, "json");
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
  const [codeCount, allCount] = await Promise.all([count(env, codeKey), count(env, allKey)]);
  if (codeCount >= perCode) return error(429, "daily_limit", "You've reached today's call limit.");
  if (allCount >= overall) return error(429, "global_limit", "Lobby is out of calls for today.");

  // Recordings stay off whatever the client asks.
  body.session.store = false;
  const response = await upstream(OPENAI_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
      // Lets OpenAI tell users apart for abuse handling without learning who they are.
      "OpenAI-Safety-Identifier": codeHash.slice(0, 32),
    },
    body: JSON.stringify(body),
  });
  // Count only calls OpenAI accepted (a failed setup costs nothing).
  if (response.ok) {
    const ttl = { expirationTtl: 3 * 24 * 3600 };
    await Promise.all([
      env.USAGE.put(codeKey, String(codeCount + 1), ttl),
      env.USAGE.put(allKey, String(allCount + 1), ttl),
    ]);
  }
  const headers = new Headers({ "Content-Type": response.headers.get("Content-Type") || "application/json" });
  for (const name of ["x-request-id", "openai-processing-ms"]) {
    const value = response.headers.get(name);
    if (value) headers.set(name, value);
  }
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
