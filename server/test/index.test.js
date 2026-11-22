import { test } from "node:test";
import assert from "node:assert/strict";
import { handle, sha256 } from "../src/index.js";

/** In-memory stand-in for a KV namespace. */
function kv(entries = {}) {
  const map = new Map(Object.entries(entries));
  return {
    map,
    async get(key, type) {
      const value = map.get(key);
      if (value === undefined) return null;
      return type === "json" ? JSON.parse(value) : value;
    },
    async put(key, value) {
      map.set(key, value);
    },
  };
}

async function setup({ calls = 0, all = 0, env = {} } = {}) {
  const hash = await sha256("friend-code");
  const day = new Date().toISOString().slice(0, 10);
  const usage = kv({ [`code:${hash}`]: JSON.stringify({ name: "Alex" }) });
  if (calls) usage.map.set(`count:${day}:${hash}`, String(calls));
  if (all) usage.map.set(`count:${day}:all`, String(all));
  const sent = [];
  const upstream = async (url, init) => {
    sent.push({ url, init });
    return new Response(JSON.stringify({ session: { id: "s1" }, transport: { sdp: "answer" } }), {
      status: 201,
      headers: { "Content-Type": "application/json", "x-request-id": "req_1" },
    });
  };
  return { env: { OPENAI_API_KEY: "sk-real", USAGE: usage, ...env }, usage, sent, upstream, hash, day };
}

function call(body, code = "friend-code") {
  return new Request("https://worker.example/v1/live/sessions", {
    method: "POST",
    headers: code ? { Authorization: `Bearer ${code}` } : {},
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

const goodBody = () => ({
  session: {
    model: "gpt-live-1.1",
    instructions: "You are Lobby.",
    audio: { output: { voice: "marin" } },
    delegation: { type: "responses", responses: { model: "gpt-5.6-terra", tools: [{ type: "web_search" }] } },
  },
  transport: { type: "webrtc", sdp: "v=0" },
});

test("forwards a valid call with the real key and counts it", async () => {
  const t = await setup();
  const pending = [];
  const response = await handle(call(goodBody()), t.env, t.upstream, { waitUntil: (p) => pending.push(p) });
  await Promise.all(pending);
  assert.equal(response.status, 201);
  assert.equal(response.headers.get("x-request-id"), "req_1");
  assert.equal((await response.json()).transport.sdp, "answer");
  assert.equal(t.sent.length, 1);
  assert.equal(t.sent[0].url, "https://api.openai.com/v1/live/sessions");
  assert.equal(t.sent[0].init.headers.Authorization, "Bearer sk-real");
  const forwarded = JSON.parse(t.sent[0].init.body);
  assert.equal(forwarded.session.store, false);
  assert.equal(forwarded.transport.sdp, "v=0");
  assert.equal(t.usage.map.get(`count:${t.day}:${t.hash}`), "1");
  assert.equal(t.usage.map.get(`count:${t.day}:all`), "1");
});

test("the invite code itself is never sent to OpenAI or stored", async () => {
  const t = await setup();
  await handle(call(goodBody()), t.env, t.upstream);
  const sent = JSON.stringify(t.sent[0].init);
  assert.ok(!sent.includes("friend-code"));
  assert.ok(![...t.usage.map.keys()].some((key) => key.includes("friend-code")));
});

test("rejects missing and unknown codes without calling OpenAI", async () => {
  const t = await setup();
  assert.equal((await handle(call(goodBody(), null), t.env, t.upstream)).status, 401);
  const wrong = await handle(call(goodBody(), "guess"), t.env, t.upstream);
  assert.equal(wrong.status, 401);
  assert.equal((await wrong.json()).error.code, "invalid_code");
  assert.equal(t.sent.length, 0);
});

test("only Wake On's models and WebRTC calls are allowed", async () => {
  const t = await setup();
  const otherModel = goodBody();
  otherModel.session.model = "gpt-6";
  assert.equal((await handle(call(otherModel), t.env, t.upstream)).status, 400);
  const otherBackend = goodBody();
  otherBackend.session.delegation.responses.model = "o9-pro";
  assert.equal((await handle(call(otherBackend), t.env, t.upstream)).status, 400);
  const websocket = goodBody();
  websocket.transport = { type: "websocket" };
  assert.equal((await handle(call(websocket), t.env, t.upstream)).status, 400);
  assert.equal((await handle(call("not json"), t.env, t.upstream)).status, 400);
  assert.equal(t.sent.length, 0);
});

test("daily limits per code and overall", async () => {
  const perCode = await setup({ calls: 40 });
  const limited = await handle(call(goodBody()), perCode.env, perCode.upstream);
  assert.equal(limited.status, 429);
  assert.equal((await limited.json()).error.code, "daily_limit");
  const overall = await setup({ all: 5, env: { GLOBAL_DAILY_CALLS: "5" } });
  assert.equal((await handle(call(goodBody()), overall.env, overall.upstream)).status, 429);
  assert.equal(perCode.sent.length + overall.sent.length, 0);
});

test("a call OpenAI refuses isn't counted", async () => {
  const t = await setup();
  const refuse = async () => new Response('{"error":{"message":"bad voice"}}', { status: 400 });
  const response = await handle(call(goodBody()), t.env, refuse);
  assert.equal(response.status, 400);
  assert.equal(t.usage.map.get(`count:${t.day}:${t.hash}`), undefined);
});

test("prewarm HEAD and health need no code", async () => {
  const t = await setup();
  const head = await handle(new Request("https://worker.example/v1/live/sessions", { method: "HEAD" }), t.env, t.upstream);
  assert.equal(head.status, 204);
  const health = await handle(new Request("https://worker.example/health"), t.env, t.upstream);
  assert.equal(health.status, 200);
  assert.equal(t.sent.length, 0);
});

test("reports each step's time in Server-Timing", async () => {
  const t = await setup();
  const response = await handle(call(goodBody()), t.env, t.upstream);
  const timing = response.headers.get("Server-Timing");
  for (const step of ["code", "limits", "openai", "total"]) {
    assert.match(timing, new RegExp(`${step};dur=\\d+`));
  }
  assert.ok(!timing.includes("friend-code"));
});

test("the reply doesn't wait for the counter writes", async () => {
  const t = await setup();
  let release;
  t.usage.put = () => new Promise((resolve) => (release = resolve));
  const pending = [];
  const response = await handle(call(goodBody()), t.env, t.upstream, { waitUntil: (p) => pending.push(p) });
  assert.equal(response.status, 201);
  assert.equal(pending.length, 1);
  release();
});
