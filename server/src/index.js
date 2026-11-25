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
//   USAGE                KV namespace: daily counters, and per-person daily totals
//                        (`stats:<day>:<name>`, kept 90 days; scripts/usage.mjs prints them)
//   DAILY_CALLS          calls per code per UTC day (default 40)
//   GLOBAL_DAILY_CALLS   calls per UTC day across everyone (default 300)
//   ALLOWED_MODELS       comma-separated voice models (default gpt-live-1.1,gpt-live-1)
//   ALLOWED_BACKEND_MODELS comma-separated delegation models (default gpt-6.1-terra,gpt-5.6-terra)
//   DAILY_SUMMARIES      memory summaries per code per UTC day (default 200; about one per note)
//
// Invite codes are signed, so checking one needs no storage: `<name>-<key id>-<signature>`,
// e.g. `alex-1-7k2mq9xd4r8w`, where the signature is the first 60 bits of
// HMAC-SHA256(signing secret, "<key id>:<name>"). scripts/invite.mjs makes them. The daily
// counts are read while OpenAI sets up the call, so KV adds no time to it.

const OPENAI_URL = "https://api.openai.com/v1/live/sessions";
const MAX_BODY_BYTES = 256 * 1024;
const RESPONSES_URL = "https://api.openai.com/v1/responses";
const SUMMARY_MODEL = "gpt-6.2-sol";
// Kept here so a code can only ask for a summary.
const SUMMARY_EFFORT = "medium";
// The app's Memory.summaryInstructions, after OptMem's merge prompt.
const SUMMARY_INSTRUCTIONS =
  "You compress a voice assistant's memory of its user. Compress the memories you're given, " +
  "oldest first, into one line of at most 280 bytes. Keep what has lasting effect, drop what " +
  "does not. Invent nothing. When they disagree, the later one wins. Reply with the line only.";
const SUMMARY_BYTES = 280;
const SUMMARY_TRIES = 3;
const MAX_SUMMARY_LINES = 16;
const MAX_SUMMARY_LINE = 400;

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
  if (url.pathname === "/v1/memory/summarize" && request.method === "POST") {
    return summarize(request, env, upstream, ctx);
  }
  if (url.pathname === "/v1/usage" && request.method === "POST") {
    return reportUsage(request, env, ctx);
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
  if (allCount >= overall) return error(429, "global_limit", "Out of calls for today.");
  // The writes run after the reply is sent (they took 195-345 ms, all of it on the call's
  // set-up). Two calls at the same moment can then both pass the limit; that's acceptable.
  if (response.ok) {
    const ttl = { expirationTtl: 3 * 24 * 3600 };
    ctx.waitUntil(Promise.all([
      env.USAGE.put(codeKey, String(codeCount + 1), ttl),
      env.USAGE.put(allKey, String(allCount + 1), ttl),
      addStats(env, name, { calls: 1 }),
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

/** One line of the assistant's memory from up to 16 lines (see the app's MemoryJob). Only the lines
 * come from the app; the prompt and model are fixed here. Nothing is stored or logged. */
async function summarize(request, env, upstream, ctx) {
  const code = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!code) return error(401, "missing_code", PROBLEMS.invalid_code);
  const check = await checkCode(code, env);
  if (check.problem) return error(401, check.problem, PROBLEMS[check.problem]);
  let lines;
  try {
    lines = (await request.json()).lines;
  } catch {
    return error(400, "bad_json", "Request body isn't JSON.");
  }
  if (!Array.isArray(lines) || lines.length === 0 || lines.length > MAX_SUMMARY_LINES ||
      !lines.every((line) => typeof line === "string" && line.length <= MAX_SUMMARY_LINE)) {
    return error(400, "not_allowed", `Send 1 to ${MAX_SUMMARY_LINES} lines of at most ${MAX_SUMMARY_LINE} characters.`);
  }
  const key = `summaries:${new Date().toISOString().slice(0, 10)}:${check.name}`;
  const used = await count(env, key);
  if (used >= Number(env.DAILY_SUMMARIES || 200)) return error(429, "daily_limit", "Enough summaries for today.");
  // A line over the limit is sent back with "too long" and written again (as OptMem does), never cut.
  const input = [{ role: "user", content: lines.join("\n") }];
  let text = "";
  const tokens = { summaries: 1, summary_input_tokens: 0, summary_output_tokens: 0 };
  for (let attempt = 0; attempt < SUMMARY_TRIES; attempt++) {
    const response = await upstream(RESPONSES_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
        "OpenAI-Safety-Identifier": (await sha256(check.name)).slice(0, 32),
      },
      body: JSON.stringify({
        model: SUMMARY_MODEL, instructions: SUMMARY_INSTRUCTIONS, input,
        store: false, max_output_tokens: 2000, reasoning: { effort: SUMMARY_EFFORT },
      }),
    });
    if (!response.ok) return error(502, "upstream", `OpenAI answered ${response.status}.`);
    const reply = await response.json();
    tokens.summary_input_tokens += (reply.usage && reply.usage.input_tokens) || 0;
    tokens.summary_output_tokens += (reply.usage && reply.usage.output_tokens) || 0;
    text = (reply.output || []).flatMap((item) => item.content || [])
      .filter((part) => part.type === "output_text").map((part) => part.text).join("").trim();
    if (!text) return error(502, "upstream", "OpenAI sent no text.");
    const bytes = new TextEncoder().encode(text).length;
    if (bytes <= SUMMARY_BYTES) break;
    if (attempt === SUMMARY_TRIES - 1) return error(502, "too_long", "The summary stayed too long.");
    input.push({ role: "assistant", content: text },
      { role: "user", content: `Too long: ${bytes} bytes, limit ${SUMMARY_BYTES}. Accented characters cost 2 bytes. Compress it further.` });
  }
  ctx.waitUntil(Promise.all([
    env.USAGE.put(key, String(used + 1), { expirationTtl: 3 * 24 * 3600 }),
    addStats(env, check.name, tokens),
  ]));
  return json(200, { text });
}

// The most one call can report; anything above is cut to this (a call is at most a few hours).
const USAGE_LIMITS = { seconds: 4 * 3600, input_tokens: 5_000_000, cached_tokens: 5_000_000, output_tokens: 500_000 };

/** The app's report at hang-up of what a call used: the voice model's billed seconds and the
 * backend's tokens. Reported by the app, so a changed app could send less; the call limits
 * don't depend on it. */
async function reportUsage(request, env, ctx) {
  const code = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!code) return error(401, "missing_code", PROBLEMS.invalid_code);
  const check = await checkCode(code, env);
  if (check.problem) return error(401, check.problem, PROBLEMS[check.problem]);
  let body;
  try {
    body = await request.json();
  } catch {
    return error(400, "bad_json", "Request body isn't JSON.");
  }
  const add = { reports: 1 };
  for (const [field, limit] of Object.entries(USAGE_LIMITS)) {
    const value = Number(body && body[field]);
    if (!Number.isFinite(value) || value < 0) return error(400, "not_allowed", `${field} must be a number of at least 0.`);
    add[field] = Math.min(value, limit);
  }
  ctx.waitUntil(addStats(env, check.name, add));
  return json(200, { ok: true });
}

/** Adds to a person's totals for today. Two writes at the same moment can lose one; fine for
 * a rough count. */
export async function addStats(env, name, add, day = new Date().toISOString().slice(0, 10)) {
  const key = `stats:${day}:${name}`;
  let stats = {};
  try {
    stats = JSON.parse((await env.USAGE.get(key)) || "{}");
  } catch {
    stats = {};
  }
  for (const [field, value] of Object.entries(add)) {
    stats[field] = Math.round(((stats[field] || 0) + value) * 10) / 10;
  }
  await env.USAGE.put(key, JSON.stringify(stats), { expirationTtl: 90 * 24 * 3600 });
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
    const backends = list(env.ALLOWED_BACKEND_MODELS, "gpt-6.1-terra,gpt-5.6-terra");
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
