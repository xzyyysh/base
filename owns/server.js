/**
 * cline2api - Fully-Local, single-file Node.js server (zero dependencies).
 *
 * Turns Cline's (https://cline.bot) free model access into an OpenAI / Anthropic
 * compatible API that runs entirely on your machine. No Cloudflare Workers, no
 * Vercel, no npm packages required.
 *
 * This file = request-handling logic (the original api/index.js, kept in sync)
 *           + local credential management + device-code login + HTTP server.
 *
 * Token sources (merged, de-duplicated, in order):
 *   1. CLINE_REFRESH_TOKEN env var (one per line, multi-account supported)
 *   2. Cline CLI config providers.json -> providers.*.settings.auth.refreshToken
 *   3. Local credentials file ~/.cline2api/credentials.json
 *
 * Features:
 *   - Zero dependencies: only Node built-ins (node >= 18; uses global
 *     fetch / Request / Response).
 *   - Hot reload: the config files are stat()'d before every request; if the
 *     mtime changed, tokens are reloaded with no restart required.
 *   - Auto login: if no token is found at startup, the official WorkOS device
 *     authorization flow is started automatically.
 *   - GET /v1/login        starts login, returns the auth URL + device code
 *   - GET /v1/login/status returns the current login state
 *   - Auto-configures opencode: creates/merges the cline2api provider on start.
 *
 * Usage:
 *   node server.js              # start the local API (default http://127.0.0.1:8787)
 *   node server.js --login      # run the device login once and save the refreshToken
 *
 * Environment variables:
 *   PORT                    listen port (default 8787)
 *   HOST                    listen host (default 127.0.0.1)
 *   API_KEY                 client access key (default cline2api-default-key)
 *   CLINE_REFRESH_TOKEN     explicit refreshToken(s), one per line (optional)
 *   CLINE_PROVIDERS_PATH    custom providers.json path
 *   CLINE2API_CREDS_PATH    custom local credentials file path
 *   CLINE_NO_AUTO_LOGIN     set to 1 to disable auto login on startup
 *   CLINE_UPDATE_PROVIDERS  set to 1 to also write the token back to providers.json
 *   CLINE2API_NO_OPENCODE   set to 1 to disable opencode auto-config
 *   CLINE2API_UPDATE_OPENCODE  set to 1 to refresh an existing cline2api provider
 *                              (models/options) instead of skipping it
 *   OPENCODE_CONFIG / OPENCODE_CONFIG_PATH   explicit opencode config file to write
 *   TG_BOT_TOKEN/TG_CHAT_ID optional, push the auth link to Telegram
 */
"use strict";

const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// ===========================================================================
// Request-handling logic (the original api/index.js, kept in sync)
// ===========================================================================

const CLINE_API_BASE = "https://api.cline.bot/api/v1";

// Account pool: supports multiple Cline accounts, each caching its own accessToken.
// CLINE_REFRESH_TOKEN may contain multiple lines, one refreshToken per line.
// When quota is exhausted (empty response), it rotates to the next account.
// Shape: { refreshToken, accessToken, expiry, cooldownUntil }
let accounts = [];
let accountIndex = 0; // round-robin cursor
let currentAccount = null; // account currently in use (safe under the serial queue)

// Model list: use the full model IDs returned by Cline /v1/models as-is.
// No artificial "cline/" prefix is added, so different providers never collide.
const MODELS = [
  { id: "cline-free/deepseek-v4.1-flash", upstream: "cline-free/deepseek-v4.1-flash", provider: "cline", cost: "free" },
  { id: "cline-free/mimo-v2.6-flash", upstream: "cline-free/mimo-v2.6-flash", provider: "cline", cost: "free" },
  { id: "cline-free/muse-spark-1.3-contributor", upstream: "cline-free/muse-spark-1.3-contributor", provider: "cline", cost: "free" },
  { id: "stealth/pixel-canary", upstream: "stealth/pixel-canary", provider: "stealth", cost: "free" },
  { id: "stealth/space-bunny-alpha", upstream: "stealth/space-bunny-alpha", provider: "stealth", cost: "free" },
  { id: "deepseek/deepseek-v4-flash", upstream: "deepseek/deepseek-v4-flash", provider: "deepseek", cost: "free" },
  { id: "z-ai/glm-5.3-flash", upstream: "z-ai/glm-5.3-flash", provider: "zai", cost: "free" },
  { id: "poolside/laguna-s-2.1:free", upstream: "poolside/laguna-s-2.1:free", provider: "poolside", cost: "free" },
  { id: "qwen/qwen3.8-27b:free", upstream: "qwen/qwen3.8-27b:free", provider: "qwen", cost: "free" },
  { id: "nvidia/nemotron-3-super-120b-a12b:free", upstream: "nvidia/nemotron-3-super-120b-a12b:free", provider: "nvidia", cost: "free" },
];

// ============ Dynamic model list ============
// Prefer Cline's official /v1/models; fall back to the built-in list above.
// Refreshed every 10 minutes.
let modelsCache = null;
let modelsCacheTime = 0;
const MODELS_TTL = 10 * 60 * 1000; // 10 minutes

async function refreshModels() {
  try {
    const now = Date.now();
    if (modelsCache && now - modelsCacheTime < MODELS_TTL) {
      return modelsCache;
    }
    const resp = await fetch(CLINE_API_BASE + "/models", {
      headers: { "User-Agent": "Mozilla/5.0 (cline2api)" },
    });
    if (!resp.ok) {
      console.log("[models] upstream fetch failed HTTP", resp.status, "- using built-in list");
      return MODELS;
    }
    const data = await resp.json();
    if (!data || !Array.isArray(data.data) || data.data.length === 0) {
      return MODELS;
    }
    // Keep only free models: ":free" suffix + Cline's official free whitelist.
    const FREE_WHITELIST = [
      "deepseek/deepseek-v4-flash",
      "deepseek/deepseek-v4-flash-0731",
      "z-ai/glm-5.3-flash",
      "xiaomi/mimo-v2.5",
      "minimax/minimax-m3",
      "poolside/laguna-s-2.1",
      "meta/muse-spark-1.3-contributor",
    ];
    const baseList = data.data
      .filter((m) => {
        const id = m.id || "";
        if (":batch" in m && m.batch) return false;
        if (id.endsWith(":batch")) return false;
        if (id.includes(":free")) return true;
        if (FREE_WHITELIST.includes(id)) return true;
        return false;
      })
      .map((m) => {
        const id = m.id || "";
        const prefix = id.split("/")[0] || "cline";
        return { id, upstream: id, provider: prefix, cost: "free" };
      });
    // Merge in the cline-free models from recommended-models.
    const freeExtra = await refreshFreeModels();
    for (const fm of freeExtra) {
      if (!baseList.some((b) => b.id === fm.id)) baseList.push(fm);
    }
    modelsCache = baseList;
    modelsCacheTime = now;
    console.log("[models] dynamic fetch OK:", modelsCache.length, "models (incl. cline-free)");
    return modelsCache;
  } catch (e) {
    console.log("[models] fetch error:", String(e).slice(0, 100), "- using built-in list");
    return MODELS;
  }
}

// =====================================================================
// Cline's official free model list (reverse-engineered from the plugin's
// recommended-models endpoint). The official plugin uses
// https://api.cline.bot/api/v1/ai/cline/recommended-models to get the free
// (cline-free/) models. These go through the official free quota and need no
// credits. Conversely, deepseek/deepseek-v4.1-flash is a paid tier and returns
// 402 insufficient_credits when the balance is empty.
// On every dynamic refresh we also pull this endpoint and merge its free list.
// =====================================================================
async function refreshFreeModels() {
  try {
    const resp = await fetch(CLINE_API_BASE + "/ai/cline/recommended-models", {
      headers: { "User-Agent": "Mozilla/5.0 (cline2api)" },
    });
    if (!resp.ok) return [];
    const data = await resp.json();
    const list = Array.isArray(data && data.free) ? data.free : [];
    return list
      .filter((m) => m && m.id)
      .map((m) => ({ id: m.id, upstream: m.id, provider: m.id.split("/")[0] || "cline", cost: "free" }));
  } catch (e) {
    return [];
  }
}

// Default model: Cline's free DeepSeek V4.1 Flash channel (cline-free/, official
// free quota, no credits required). Reverse-engineered from the recommended-models
// free list: cline-free/deepseek-v4.1-flash
const DEFAULT_MODEL = "cline-free/deepseek-v4.1-flash";
const VERSION = "1.2.0";

// The original Worker fetch handler.
async function clineFetchHandler(request, env) {
  const url = new URL(request.url);

  // CORS preflight
  if (request.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(),
    });
  }

  // Health/diagnostic endpoint (no auth, useful to verify env vars are loaded)
  if (request.method === "GET" && url.pathname === "/v1/health") {
    const poolN = parseAccounts(env).length;
    return jsonResponse({
      ok: true,
      version: VERSION,
      authenticated: !!env.API_KEY,
      accounts: poolN,
      model: DEFAULT_MODEL,
    }, 200);
  }

  // Global auth: every endpoint requires an API key (except the OPTIONS preflight).
  // If API_KEY is not configured, the built-in default key is used:
  // "cline2api-default-key". (Optional) Setting API_KEY="" disables auth entirely.
  // GET /v1/models is unauthenticated so GUIs can validate and list models
  // (write endpoints like chat still require auth; public models is the standard
  // approach for proxies such as kilo).
  if (request.method === "GET" && (url.pathname === "/v1/models" || url.pathname === "/models")) {
    return handleModels();
  }

  // POST chat endpoints
  if (request.method === "POST") {
    if (url.pathname === "/v1/chat/completions" || url.pathname === "/chat/completions") {
      return handleChat(request, env);
    }
    if (url.pathname === "/v1/messages" || url.pathname === "/messages") {
      return handleAnthropic(request, env);
    }
  }

  return jsonResponse({ error: { message: "Not found", type: "not_found" } }, 404);
}

// ---------------------------------------------------------------------------
// Token management
// ---------------------------------------------------------------------------

// Parse the account pool from the env var: one CLINE_REFRESH_TOKEN per line.
function parseAccounts(env) {
  const raw = env.CLINE_REFRESH_TOKEN || "";
  const tokens = raw.split("\n").map((s) => s.trim()).filter((s) => s.length > 8);
  if (tokens.length === 0) return [];

  // If the token list changed (accounts added/removed), rebuild the pool.
  const changed =
    accounts.length !== tokens.length ||
    accounts.some((a, i) => a.refreshToken !== tokens[i]);
  if (changed) {
    accounts = tokens.map((rt) => ({
      refreshToken: rt,
      accessToken: null,
      expiry: 0,
      cooldownUntil: 0,
    }));
  }
  return accounts;
}

// Get an account's accessToken (independent cache; refresh on expiry/cooldown).
async function getAccountToken(account) {
  const now = Date.now();
  // Unavailable while in cooldown.
  if (account.cooldownUntil > now) {
    throw new Error("account_cooldown");
  }
  if (account.accessToken && now < account.expiry) {
    return account.accessToken;
  }
  const resp = await fetch(CLINE_API_BASE + "/auth/refresh", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      refreshToken: account.refreshToken,
      grantType: "refresh_token",
    }),
  });
  if (!resp.ok) {
    // Refresh failed: cool down for 60s and let the caller rotate accounts.
    account.cooldownUntil = now + 60 * 1000;
    throw new Error("refresh_failed");
  }
  const data = await resp.json();
  const accessToken = data && data.data && data.data.accessToken;
  if (!accessToken) {
    account.cooldownUntil = now + 60 * 1000;
    throw new Error("refresh_no_token");
  }
  account.accessToken = accessToken;
  // Cline rotates the refreshToken on refresh; persist the new one to avoid an
  // invalid_grant on the next refresh.
  if (typeof (data.data || {}).refreshToken === "string" && data.data.refreshToken.trim()) {
    account.refreshToken = data.data.refreshToken.trim();
  }
  // Expiry: prefer the server value, otherwise 10 minutes, minus 60s of slack.
  const expiresAt = data && data.data && data.data.expiresAt;
  let expiry = now + 10 * 60 * 1000;
  if (typeof expiresAt === "number") {
    expiry = expiresAt;
  } else if (typeof expiresAt === "string") {
    const t = Date.parse(expiresAt);
    if (!isNaN(t)) expiry = t;
  }
  account.expiry = expiry - 60000;
  return accessToken;
}

// Round-robin to pick an available account, set currentAccount, and return it.
function pickAccount(pool) {
  for (let k = 0; k < pool.length; k++) {
    const acc = pool[accountIndex % pool.length];
    accountIndex = (accountIndex + 1) % pool.length;
    if (!acc.cooldownUntil || acc.cooldownUntil <= Date.now()) {
      currentAccount = acc;
      return acc;
    }
  }
  return null; // all accounts are cooling down
}

async function getAccessToken(env) {
  const pool = parseAccounts(env);
  if (pool.length === 0) {
    throw new Error("missing CLINE_REFRESH_TOKEN environment variable");
  }
  // Try up to pool.length accounts (skip cooled-down / failed refreshes).
  for (let attempt = 0; attempt < pool.length; attempt++) {
    const acc = pool[attempt % pool.length]; // try each in turn
    if (acc.cooldownUntil && acc.cooldownUntil > Date.now()) continue;
    currentAccount = acc;
    try {
      return await getAccountToken(acc);
    } catch (e) {
      if (e.message === "account_cooldown") continue;
      continue; // a failed refresh also rotates to the next account
    }
  }
  // All failed: clear the cooldown and retry the first one once.
  const acc = pool[0];
  currentAccount = acc;
  acc.cooldownUntil = 0;
  try {
    return await getAccountToken(acc);
  } catch (e) {
    throw new Error("all accounts failed to refresh token");
  }
}

// Cline client fingerprint headers (the official API uses these to decide whether
// the caller is a real Cline client). Without them you get 403:
// "deepseek/deepseek-v4-flash is only available via Cline product surfaces".
// Key point: the Cline API inspects request headers, and requests without the
// spoofed headers get a 403 ("only available via Cline product surfaces"). The
// headers below impersonate the official Cline client (3.0.47), which bypasses it.
// Verified: same refreshToken, raw curl -> 403; via clineHeaders -> 429 rate limit
// (normal quota state). DO NOT remove these headers, or the deepseek free channel
// immediately returns 403.
function clineHeaders(sessionId) {
  return {
    Authorization: "Bearer workos:" + currentToken,
    "Content-Type": "application/json",
    "User-Agent": "Cline/3.0.47",
    "HTTP-Referer": "https://cline.bot",
    "X-Title": "Cline",
    "X-IS-MULTIROOT": "false",
    "X-CLIENT-TYPE": "cline-sdk",
    "X-CLIENT-VERSION": "3.0.47",
    "X-PLATFORM": "terminal",
    "X-PLATFORM-VERSION": "3.0.47",
    "X-CORE-VERSION": "0.0.66",
    "X-Task-ID": sessionId,
  };
}

// The current account's accessToken (used by clineHeaders).
let currentToken = "";

async function clineFetch(env, pathName, bodyObj, sessionId, retried = false) {
  const token = await getAccessToken(env);
  currentToken = token;
  const headers = clineHeaders(sessionId);
  headers.Authorization = "Bearer workos:" + token;
  const resp = await fetch(CLINE_API_BASE + pathName, {
    method: "POST",
    headers,
    body: JSON.stringify(bodyObj),
  });
  if (resp.status === 401 && !retried) {
    // Token expired: mark the current account as cooling down and retry forcefully
    // (will use another account / a refresh).
    if (currentAccount) {
      currentAccount.cooldownUntil = Date.now() + 60 * 1000;
      currentAccount.accessToken = null;
      currentAccount.expiry = 0;
    }
    return clineFetch(env, pathName, bodyObj, sessionId, true);
  }
  return resp;
}

// ---------------------------------------------------------------------------
// Concurrency queue: the upstream free channel returns an empty response when
// concurrency exceeds 1, so force serial execution plus a minimum gap.
// ---------------------------------------------------------------------------

let queueTail = Promise.resolve(); // global serial queue tail
const MIN_GAP_MS = 800; // minimum gap between two upstream requests

function enqueue(fn) {
  // After the previous task finishes, wait the gap, then run fn.
  const run = queueTail.then(() => sleep(MIN_GAP_MS)).then(fn);
  // Keep the chain alive regardless of success/failure so the queue never breaks.
  queueTail = run.catch(() => {});
  return run;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// Parse the wait time from an upstream 429/rate-limit response and return ms.
// Supported formats: "Try again in 2h 51m" / "Try again in 30m" / "Try again in 1h" / "Try again in 15s"
function parseCooldown(body, status) {
  const m = (body || "").match(/try again in (?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?/i);
  if (m) {
    const h = parseInt(m[1] || 0, 10);
    const min = parseInt(m[2] || 0, 10);
    const s = parseInt(m[3] || 0, 10);
    const ms = (h * 3600 + min * 60 + s) * 1000;
    if (ms > 0) return Math.min(ms, 6 * 3600 * 1000); // cap at 6 hours
  }
  // 429 defaults to 5 minutes; empty response defaults to 60 seconds.
  if (status === 429) return 5 * 60 * 1000;
  return 60 * 1000;
}

// clineFetch with retries: on 429 rate limit / empty response / 5xx, switch
// accounts automatically with exponential backoff.
// When one account runs out of quota or is rate limited (429 Daily free limit
// reached):
//   - cool down that account (for the duration the upstream suggests, e.g. 2h51m)
//   - rotate to the next account and retry the same request
// When all accounts are cooling down, return the raw response (no spin-looping).
async function clineFetchWithRetry(env, pathName, bodyObj, sessionId, isStream = false, maxRetries = 4) {
  let lastResp = null;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    // Run serially through the queue to avoid concurrent empty responses.
    const resp = await enqueue(() => clineFetch(env, pathName, bodyObj, sessionId));
    lastResp = resp;

    // Read the body uniformly (clone does not consume the stream).
    let bodyText = "";
    try {
      bodyText = await resp.clone().text();
    } catch (e) {}

    // Detect "quota/rate limit" signals (need to rotate accounts):
    // 1. 429 (Daily free limit reached / rate limit)
    // 2. 5xx containing "empty response content"
    // 3. 200 non-stream body that is an empty-response envelope
    const isLimitHit =
      resp.status === 429 ||
      (resp.status >= 500 && bodyText.includes("empty response content")) ||
      (resp.ok && !isStream && bodyText.includes("empty response content"));

    if (isLimitHit) {
      const cooldownMs = parseCooldown(bodyText, resp.status);
      if (currentAccount) {
        currentAccount.cooldownUntil = Date.now() + cooldownMs;
        currentAccount.accessToken = null;
        currentAccount.expiry = 0;
        console.log(`[account-switch] account quota/rate limited, cooling down ${Math.round(cooldownMs / 1000)}s, switching`);
      }
      // If another account is available -> short backoff then retry (rotates).
      const pool = parseAccounts(env);
      const hasOther = pool.some((a) => !a.cooldownUntil || a.cooldownUntil <= Date.now());
      if (!hasOther) {
        console.log("[retry] all accounts cooling down, returning upstream response");
        return resp; // no spin-looping; return the 429/error to the client
      }
      await sleep(500 + Math.floor(Math.random() * 500));
      continue;
    }

    // Normal response (200)
    if (resp.ok) {
      if (isStream) return resp; // streaming: forward directly
      return resp; // non-streaming: body already confirmed non-empty
    }

    // Other errors (403/400/401, etc.) are not retried; return them directly.
    return resp;
  }
  // Retries exhausted; return the last response.
  return lastResp;
}

// ---------------------------------------------------------------------------
// OpenAI protocol
// ---------------------------------------------------------------------------

async function handleChat(request, env) {
  // API key auth
  const key = getApiKey(request, env);
  if (!key) {
    return jsonResponse({ error: { message: "Invalid API key", type: "auth_error" } }, 401);
  }

  let params;
  try {
    params = await request.json();
  } catch (e) {
    return jsonResponse({ error: { message: "Invalid JSON body", type: "parse_error" } }, 400);
  }

  const isStream = !!params.stream;
  const sessionId = "sess_" + Date.now();
  const model = params.model || DEFAULT_MODEL;
  const modelConfig = (await refreshModels()).find((m) => m.id === model);
  const upstreamModel = (modelConfig && modelConfig.upstream) || model;

  // Build the upstream body (external model ID separated from Cline upstream ID).
  const body = {
    model: upstreamModel,
    session_id: sessionId,
    reasoning_effort: params.reasoning_effort || params.reasoningEffort || "high",
    messages: params.messages || [],
  };
  // Upstream policy: free models return 500 "empty response content" when the body
  // contains max_tokens, so strip it.
  // Free DeepSeek channel: non-streaming requests are rate limited upstream
  // (500 empty response content) while streaming works, so when the client asks
  // for non-streaming we force upstream streaming and aggregate afterwards.
  const forceStream = !isStream && (upstreamModel.startsWith("deepseek/") || upstreamModel.startsWith("cline-free/") || upstreamModel.startsWith("cline-pass/"));
  if (isStream || forceStream) body.stream = true;
  // Pass through optional params
  for (const k of ["temperature", "top_p", "tools", "tool_choice", "stop", "presence_penalty", "frequency_penalty", "response_format", "user", "n", "seed"]) {
    if (params[k] !== undefined) body[k] = params[k];
  }

  try {
    const resp = await clineFetchWithRetry(env, "/chat/completions", body, sessionId, true);
    if (!resp.ok) {
      const errText = await resp.text();
      return jsonResponse({ error: { message: "upstream error: " + errText.slice(0, 300), type: "api_error" } }, resp.status);
    }
    if (isStream) {
      // Client wants streaming: forward the SSE directly.
      return streamResponse(resp, model);
    }
    if (forceStream) {
      // Client wants non-streaming but upstream is streaming: aggregate chunks.
      // The free channel (deepseek/cline-free) can sporadically return a stream
      // that is HTTP 200 but has empty content all the way through (100 chunks of
      // reasoning, no real content). Detect that and rotate accounts on empty.
      const retried = await nonStreamWithContentCheck(env, "/chat/completions", body, sessionId, resp);
      if (retried.error) return retried.error;
      retried.data.model = model;
      return jsonResponse(retried.data, 200);
    }
    // Non-streaming + non-deepseek: original path.
    const raw = await resp.json();
    const normalized = unwrapData(raw);
    normalized.model = model;
    return jsonResponse(normalized, 200);
  } catch (e) {
    return jsonResponse({ error: { message: e.message, type: "api_error" } }, 500);
  }
}

// Aggregate an upstream SSE stream into an OpenAI non-streaming response object.
// Used when "the client wants non-streaming but upstream only streams"
// (deepseek free channel).
// Extra handling: upstream returns 200 with all-empty content (only reasoning) ->
// treat it as a bad response and rotate accounts on retry.
// The caller passes the already-obtained upstream response; this aggregates it,
// checks the content, and retries on empty.
async function nonStreamWithContentCheck(env, pathName, bodyObj, sessionId, firstResp) {
  const maxAttempts = 3; // try up to 3 times (covers multi-account rotation)
  let lastData = null;
  let resp = firstResp;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    if (!resp) {
      // Need a fresh upstream request (on empty-response retry).
      resp = await clineFetchWithRetry(env, pathName, bodyObj, sessionId, true);
    }
    if (!resp.ok) {
      const errText = await resp.text().catch(() => "");
      return { error: jsonResponse({ error: { message: "upstream error: " + errText.slice(0, 300), type: "api_error" } }, resp.status) };
    }
    const ct = resp.headers.get("content-type") || "";
    let normalized = null;
    if (ct.includes("text/event-stream")) {
      normalized = await streamToNonStream(resp);
    } else {
      const raw = await resp.json().catch(() => null);
      if (raw) normalized = unwrapData(raw);
    }
    if (!normalized) {
      return { error: jsonResponse({ error: { message: "upstream returned non-SSE body", type: "api_error" } }, 502) };
    }
    lastData = normalized;
    const msg = (normalized && normalized.choices && normalized.choices[0] && normalized.choices[0].message) || {};
    const content = (msg.content || "").trim();
    const reasoning = (msg.reasoning || "").trim();
    // reasoning fallback marker: when content is empty, streamToNonStream folds the
    // reasoning into content. Detect that here so it is not treated as a good response.
    const isReasoningFallback = msg.reasoning_used_as_content === true;
    if (content && !isReasoningFallback) {
      return { data: normalized }; // has real content -> good response
    }
    // Empty content (or only fallback reasoning): if there is reasoning, mark the
    // current account as cooling down and retry.
    if (reasoning || isReasoningFallback) {
      if (currentAccount) {
        currentAccount.cooldownUntil = Date.now() + 30 * 1000; // short 30s cooldown
        currentAccount.accessToken = null;
        currentAccount.expiry = 0;
        console.log(`[empty-content] account ${attempt} returned empty content, cooling down 30s, retrying attempt ${attempt + 2}`);
      }
      await sleep(300 + Math.floor(Math.random() * 300));
      resp = null; // re-request next loop (rotates to the next account)
      continue;
    }
    // Completely empty (not even reasoning) -> also retry.
    console.log(`[empty-response] account ${attempt} returned a completely empty response, retrying attempt ${attempt + 2}`);
    await sleep(300 + Math.floor(Math.random() * 300));
    resp = null;
  }
  // Retries exhausted and still empty: return the last one (at least it has
  // reasoning, so the client sees something).
  return { data: lastData };
}

async function streamToNonStream(upstream) {
  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  let content = "";
  let reasoning = "";
  let finishReason = null;
  let model = "";
  let id = "";
  let usage = null;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (payload === "" || payload === "[DONE]") continue;
      try {
        const obj = JSON.parse(payload);
        const normalized = unwrapData(obj);
        const choice = normalized && normalized.choices && normalized.choices[0];
        if (!choice) continue;
        const delta = choice.delta || {};
        if (delta.content) content += delta.content;
        if (delta.reasoning) reasoning += delta.reasoning;
        if (choice.finish_reason) finishReason = choice.finish_reason;
        if (normalized.id) id = normalized.id;
        if (normalized.model) model = normalized.model;
        if (normalized.usage) usage = normalized.usage;
      } catch (e) {}
    }
  }

  const msg = { role: "assistant", content };
  if (reasoning) msg.reasoning = reasoning;
  // Fallback: the free channel occasionally returns a stream with only reasoning
  // and no content (HTTP 200 but empty). When the aggregation finishes and content
  // is still empty while reasoning is not, fold the reasoning into content so the
  // client (qwenpaw, etc.) at least receives visible content instead of staying
  // silent.
  if (!content && reasoning) {
    msg.content = reasoning;
    msg.reasoning_used_as_content = true;
  }
  return {
    id: id || "gen_" + Date.now(),
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model: model || DEFAULT_MODEL,
    choices: [{
      index: 0,
      message: msg,
      finish_reason: finishReason || "stop",
      logprobs: null,
      native_finish_reason: finishReason || "stop",
    }],
    usage: usage || { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  };
}

// ---------------------------------------------------------------------------
// Anthropic Messages API -> convert to OpenAI format and forward
// ---------------------------------------------------------------------------

async function handleAnthropic(request, env) {
  const key = getApiKey(request, env);
  if (!key) {
    return jsonResponse({ error: { message: "Invalid API key", type: "auth_error" } }, 401);
  }

  let req;
  try {
    req = await request.json();
  } catch (e) {
    return jsonResponse({ error: { message: "Invalid JSON body", type: "parse_error" } }, 400);
  }

  const isStream = !!req.stream;
  const sessionId = "sess_" + Date.now();
  const requestedModel = req.model || DEFAULT_MODEL;
  const modelConfig = (await refreshModels()).find((m) => m.id === requestedModel);
  const upstreamModel = (modelConfig && modelConfig.upstream) || requestedModel;

  // Anthropic -> OpenAI message conversion
  const messages = [];
  if (req.system) {
    const sysContent = typeof req.system === "string" ? req.system : JSON.stringify(req.system);
    messages.push({ role: "system", content: sysContent });
  }
  for (const m of req.messages || []) {
    const content = typeof m.content === "string" ? m.content : JSON.stringify(m.content);
    messages.push({ role: m.role, content });
  }

  const body = {
    model: upstreamModel,
    session_id: sessionId,
    reasoning_effort: "high",
    messages,
  };
  // Upstream policy: free models return 500 when the body contains max_tokens,
  // so strip it (same as the chat/completions path).
  // Free DeepSeek channel: non-streaming is rate limited upstream, so force
  // upstream streaming and aggregate.
  const forceStream = !isStream && (upstreamModel.startsWith("deepseek/") || upstreamModel.startsWith("cline-free/") || upstreamModel.startsWith("cline-pass/"));
  if (isStream || forceStream) body.stream = true;
  if (req.temperature !== undefined) body.temperature = req.temperature;
  if (req.top_p !== undefined) body.top_p = req.top_p;
  if (req.tools) {
    body.tools = req.tools.map((t) => ({
      type: "function",
      function: { name: t.name, description: t.description || "", parameters: t.input_schema || {} },
    }));
  }

  try {
    const resp = await clineFetchWithRetry(env, "/chat/completions", body, sessionId, true);
    if (!resp.ok) {
      const errText = await resp.text();
      return jsonResponse({ error: { message: "upstream error: " + errText.slice(0, 300), type: "api_error" } }, resp.status);
    }
    if (isStream) {
      // Upstream is OpenAI SSE; convert to Anthropic SSE format.
      return streamResponseAnthropic(resp);
    }
    if (forceStream) {
      // Client wants non-streaming but upstream streams: aggregate then convert.
      // Same content check: the free channel can return a "200 but all-empty" stream.
      const retried = await nonStreamWithContentCheck(env, "/chat/completions", body, sessionId, resp);
      if (retried.error) return retried.error;
      return jsonResponse(openAItoAnthropic(retried.data), 200);
    }
    const raw = await resp.json();
    const normalized = unwrapData(raw);
    // OpenAI -> Anthropic
    return jsonResponse(openAItoAnthropic(normalized), 200);
  } catch (e) {
    return jsonResponse({ error: { message: e.message, type: "api_error" } }, 500);
  }
}

// ---------------------------------------------------------------------------
// Response handling
// ---------------------------------------------------------------------------

// Strip the upstream {data:{...}} envelope (upstream sometimes wraps in data).
function unwrapData(obj) {
  if (obj && obj.data && typeof obj.data === "object") {
    const d = obj.data;
    if (d.choices || d.id || d.usage) return d;
  }
  return obj;
}

// OpenAI SSE passthrough (strips the data envelope).
async function streamResponse(upstream, externalModel) {
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  let buf = "";
  (async () => {
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        // Process line by line
        let idx;
        while ((idx = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, idx);
          buf = buf.slice(idx + 1);
          if (line.startsWith("data:")) {
            const payload = line.slice(5).trim();
            if (payload === "" || payload === "[DONE]") {
              await writer.write(encoder.encode(line + "\n\n"));
              continue;
            }
            try {
              const obj = JSON.parse(payload);
              const normalized = unwrapData(obj);
              if (normalized && externalModel) normalized.model = externalModel;
              await writer.write(encoder.encode("data: " + JSON.stringify(normalized) + "\n\n"));
            } catch (e) {
              await writer.write(encoder.encode(line + "\n"));
            }
          } else {
            await writer.write(encoder.encode(line + "\n"));
          }
        }
      }
    } catch (e) {
      // ignore
    } finally {
      try { await writer.close(); } catch (e) {}
    }
  })();

  return new Response(readable, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      ...corsHeaders(),
    },
  });
}

// Anthropic SSE: convert upstream OpenAI chunks into Anthropic format.
async function streamResponseAnthropic(upstream) {
  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const reader = upstream.body.getReader();
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();

  let buf = "";
  (async () => {
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        let idx;
        while ((idx = buf.indexOf("\n")) >= 0) {
          const line = buf.slice(0, idx);
          buf = buf.slice(idx + 1);
          if (line.startsWith("data:")) {
            const payload = line.slice(5).trim();
            if (payload === "" || payload === "[DONE]") continue;
            try {
              const obj = JSON.parse(payload);
              const normalized = unwrapData(obj);
              const choice = normalized && normalized.choices && normalized.choices[0];
              if (!choice) continue;
              const delta = choice.delta || {};
              if (delta.content) {
                await writer.write(encoder.encode("event: content_block_delta\ndata: " + JSON.stringify({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: delta.content } }) + "\n\n"));
              }
              if (delta.tool_calls && delta.tool_calls.length > 0) {
                for (const tc of delta.tool_calls) {
                  await writer.write(encoder.encode("event: content_block_delta\ndata: " + JSON.stringify({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify(tc.function && tc.function.arguments || "") } }) + "\n\n"));
                }
              }
            } catch (e) {}
          }
        }
      }
      // End events
      await writer.write(encoder.encode("event: message_delta\ndata: " + JSON.stringify({ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 0 } }) + "\n\n"));
      await writer.write(encoder.encode("event: message_stop\ndata: " + JSON.stringify({ type: "message_stop" }) + "\n\n"));
    } catch (e) {
    } finally {
      try { await writer.close(); } catch (e) {}
    }
  })();

  return new Response(readable, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      ...corsHeaders(),
    },
  });
}

// OpenAI non-streaming -> Anthropic non-streaming
function openAItoAnthropic(openAI) {
  const choice = openAI && openAI.choices && openAI.choices[0];
  const content = (choice && choice.message && choice.message.content) || "";
  return {
    id: (openAI && openAI.id) || "msg_" + Date.now(),
    type: "message",
    role: "assistant",
    model: (openAI && openAI.model) || "",
    content: [{ type: "text", text: content }],
    stop_reason: "end_turn",
    usage: {
      input_tokens: (openAI && openAI.usage && openAI.usage.prompt_tokens) || 0,
      output_tokens: (openAI && openAI.usage && openAI.usage.completion_tokens) || 0,
    },
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function handleModels() {
  const list = await refreshModels();
  const payload = list.map((m) => ({
    id: m.id,
    object: "model",
    created: Math.floor(Date.now() / 1000),
    owned_by: "cline",
  }));
  return jsonResponse({ object: "list", data: payload }, 200, { "X-Cline2api-Version": VERSION });
}

function getApiKey(request, env) {
  const provided = env.API_KEY;
  // If API_KEY is not configured -> use the built-in default key.
  const expected = provided !== undefined && provided !== null && provided !== "" ? provided : "cline2api-default-key";

  const auth = request.headers.get("Authorization") || "";
  if (auth.startsWith("Bearer ")) {
    return auth.slice(7) === expected ? expected : null;
  }
  const xKey = request.headers.get("x-api-key");
  return xKey === expected ? expected : null;
}

function jsonResponse(obj, status, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(), ...extraHeaders },
  });
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, x-api-key, anthropic-version, anthropic-beta",
  };
}

// ===========================================================================
// Local credential management + device authorization login
// (the JS port of cline_oauth.py)
// ===========================================================================

const HOME = os.homedir();

const WORKOS_DEVICE = "https://api.workos.com/user_management/authorize/device";
const WORKOS_AUTH = "https://api.workos.com/user_management/authenticate";
const CLINE_REGISTER = "https://api.cline.bot/api/v1/auth/register";
const CLIENT_ID = "client_01K3A541FN8TA3EPPHTD2325AR";

const PORT = parseInt(process.env.PORT || "8787", 10);
const HOST = process.env.HOST || "127.0.0.1";
const PROVIDERS_PATH =
  process.env.CLINE_PROVIDERS_PATH ||
  path.join(HOME, ".cline", "data", "settings", "providers.json");
const LOCAL_CREDS_PATH =
  process.env.CLINE2API_CREDS_PATH ||
  path.join(HOME, ".cline2api", "credentials.json");
const AUTO_LOGIN = process.env.CLINE_NO_AUTO_LOGIN !== "1";
const UPDATE_PROVIDERS = process.env.CLINE_UPDATE_PROVIDERS === "1";
const LOGIN_MODE = process.argv.includes("--login");
const OPENCODE_CONFIG_PATH =
  process.env.OPENCODE_CONFIG || process.env.OPENCODE_CONFIG_PATH || "";
const SKIP_OPENCODE = process.env.CLINE2API_NO_OPENCODE === "1";
const FORCE_OPENCODE = process.env.CLINE2API_UPDATE_OPENCODE === "1";

// Capture the env-var tokens once at startup.
// Note: syncEnv() writes its merged result back into process.env.CLINE_REFRESH_TOKEN.
// If getTokens() read process.env every time, it would create a self-feedback loop
// that resurrects stale tokens, so an account deleted from the file would survive a
// hot reload. Pinning the startup value avoids that.
const ENV_REFRESH_TOKENS = (process.env.CLINE_REFRESH_TOKEN || "")
  .split("\n")
  .map((s) => s.trim())
  .filter((s) => s.length > 8);

const fileMtimes = new Map(); // path -> mtimeMs (for hot-reload detection)
let cachedTokens = [];

function readJsonSafe(p) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch (e) {
    return null;
  }
}

// Extract every provider's refreshToken from providers.json.
function tokensFromProviders(obj) {
  const out = [];
  const providers = obj && obj.providers;
  if (!providers || typeof providers !== "object") return out;
  for (const key of Object.keys(providers)) {
    const auth = providers[key] && providers[key].settings && providers[key].settings.auth;
    if (auth && typeof auth.refreshToken === "string") out.push(auth.refreshToken);
  }
  return out;
}

// Extract tokens from the local credentials file (supports the refreshTokens
// array and a single refreshToken).
function tokensFromLocal(obj) {
  if (!obj || typeof obj !== "object") return [];
  const out = [];
  if (Array.isArray(obj.refreshTokens)) {
    for (const t of obj.refreshTokens) if (typeof t === "string") out.push(t);
  }
  if (typeof obj.refreshToken === "string") out.push(obj.refreshToken);
  return out;
}

// Read all currently available tokens (with mtime-based hot-reload detection).
function getTokens(force = false) {
  let changed = force;
  for (const p of [PROVIDERS_PATH, LOCAL_CREDS_PATH]) {
    let mt = 0;
    try {
      mt = fs.statSync(p).mtimeMs;
    } catch (e) {}
    if (fileMtimes.get(p) !== mt) {
      fileMtimes.set(p, mt);
      changed = true;
    }
  }
  if (!changed && cachedTokens.length) {
    if (process.env.CLINE2API_DEBUG) console.log("[cred] cached", cachedTokens.length, "token(s)");
    return cachedTokens;
  }

  const list = [];
  const push = (t) => {
    if (typeof t !== "string") return;
    const v = t.trim();
    if (v.length > 8 && !list.includes(v)) list.push(v);
  };

  // 1) env vars (the startup-captured values, to avoid self-feedback)
  ENV_REFRESH_TOKENS.forEach(push);
  // 2) Cline CLI config
  const prov = readJsonSafe(PROVIDERS_PATH);
  if (prov) tokensFromProviders(prov).forEach(push);
  // 3) local credentials file
  const local = readJsonSafe(LOCAL_CREDS_PATH);
  if (local) tokensFromLocal(local).forEach(push);

  cachedTokens = list;
  if (process.env.CLINE2API_DEBUG) console.log("[cred] reloaded", list.length, "token(s)");
  return cachedTokens;
}

// Sync the latest token list into process.env; the request logic reads it per request.
function syncEnv(force = false) {
  const tokens = getTokens(force);
  process.env.CLINE_REFRESH_TOKEN = tokens.join("\n");
  return tokens;
}

// Persist a login result to the local credentials file (append, de-duplicate).
function saveLocalToken(refreshToken) {
  const obj = readJsonSafe(LOCAL_CREDS_PATH) || {};
  const list = tokensFromLocal(obj);
  if (!list.includes(refreshToken)) list.push(refreshToken);
  const out = {
    refreshTokens: list,
    updatedAt: new Date().toISOString(),
  };
  fs.mkdirSync(path.dirname(LOCAL_CREDS_PATH), { recursive: true });
  fs.writeFileSync(LOCAL_CREDS_PATH, JSON.stringify(out, null, 2) + "\n", {
    mode: 0o600,
  });
}

// Optional: write the login result back to Cline CLI's providers.json so both stay
// signed in.
function updateProvidersFile(auth) {
  if (!UPDATE_PROVIDERS) return;
  const obj = readJsonSafe(PROVIDERS_PATH);
  if (!obj || !obj.providers || !obj.providers.cline) return;
  obj.providers.cline.settings = obj.providers.cline.settings || {};
  obj.providers.cline.settings.auth = auth;
  obj.providers.cline.updatedAt = new Date().toISOString();
  obj.providers.cline.tokenSource = "oauth";
  fs.writeFileSync(PROVIDERS_PATH, JSON.stringify(obj, null, 2) + "\n");
}

async function postForm(url, form) {
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(form),
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${(await resp.text()).slice(0, 300)}`);
  return resp.json();
}

async function postJson(url, body) {
  const resp = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${(await resp.text()).slice(0, 300)}`);
  return resp.json();
}

async function sendTelegram(text) {
  const token = process.env.TG_BOT_TOKEN;
  const chat = process.env.TG_CHAT_ID;
  if (!token || !chat) return false;
  try {
    const resp = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text }),
    });
    return resp.ok;
  } catch (e) {
    return false;
  }
}

// 1) Start the WorkOS device authorization.
async function deviceAuth() {
  const resp = await postForm(WORKOS_DEVICE, { client_id: CLIENT_ID });
  return {
    deviceCode: resp.device_code,
    userCode: resp.user_code,
    url: resp.verification_uri_complete || resp.verification_uri,
    interval: Math.max(resp.interval || 5, 5),
    expiresIn: resp.expires_in || 300,
  };
}

// 2) Poll WorkOS until the user completes authorization.
async function pollWorkOS(deviceCode, interval, expiresIn) {
  const envTimeout = parseInt(process.env.OAUTH_POLL_TIMEOUT || "", 10);
  if (!Number.isNaN(envTimeout)) expiresIn = envTimeout;
  const deadline = Date.now() + expiresIn * 1000;
  let gap = Math.max(interval, 5);
  while (Date.now() < deadline) {
    await sleep(gap * 1000);
    try {
      const a = await postForm(WORKOS_AUTH, {
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: deviceCode,
        client_id: CLIENT_ID,
      });
      if (a.access_token) return a;
      if (a.error === "slow_down") gap += 5;
      else if (a.error && a.error !== "authorization_pending") {
        console.log(`   [${a.error}] ${a.error_description || ""}`);
      }
    } catch (e) {
      console.log("   poll error:", String(e).slice(0, 120));
    }
  }
  throw new Error("authorization timed out");
}

// 3) Exchange the WorkOS token for a Cline refreshToken and persist it.
async function completeLogin(workos) {
  const cline = await postJson(CLINE_REGISTER, {
    accessToken: workos.access_token,
    refreshToken: workos.refresh_token,
  });
  const data = (cline && cline.data) || {};
  const rt = data.refreshToken;
  if (!rt) {
    throw new Error("register failed: " + JSON.stringify(cline).slice(0, 300));
  }
  saveLocalToken(rt);
  updateProvidersFile({
    accessToken: "workos:" + workos.access_token,
    refreshToken: rt,
    expiresAt: Date.now() + 3600 * 1000,
    accountId: (data.userInfo && data.userInfo.clineUserId) || data.accountId,
    metadata: { provider: "cline", tokenType: "Bearer", userInfo: data.userInfo },
  });
  return { refreshToken: rt, email: (data.userInfo && data.userInfo.email) || "unknown" };
}

// Print the auth instructions and (optionally) push them to Telegram.
async function announceAuth(dev) {
  console.log("=".repeat(60));
  console.log("1) Open this URL in your browser:");
  console.log("   " + dev.url);
  console.log("2) Enter the device code when prompted (may be pre-filled):");
  console.log("   " + dev.userCode);
  console.log("3) Sign in and authorize with Google / GitHub / email");
  console.log("=".repeat(60));
  if (process.env.TG_BOT_TOKEN && process.env.TG_CHAT_ID) {
    const ok = await sendTelegram(
      "Cline authorization request\n\n" +
        "Open this URL in your browser and authorize (the code may be pre-filled):\n" +
        dev.url +
        "\n\nDevice code: " + dev.userCode +
        `\nThe script will poll automatically for up to ${dev.expiresIn} seconds.`
    );
    console.log(ok ? "Auth link pushed to Telegram." : "Telegram push failed.");
  }
}

// Full interactive login (used by --login mode).
async function runLoginInteractive() {
  console.log("Starting the Cline WorkOS device authorization flow...\n");
  const dev = await deviceAuth();
  await announceAuth(dev);
  console.log(`\nWaiting for authorization (up to ${dev.expiresIn}s)...`);
  const workos = await pollWorkOS(dev.deviceCode, dev.interval, dev.expiresIn);
  console.log("WorkOS authorization OK!\nExchanging the WorkOS token with Cline...");
  const result = await completeLogin(workos);
  console.log("\n" + "=".repeat(60));
  console.log(`Login OK! Account: ${result.email}`);
  console.log(`refreshToken saved to: ${LOCAL_CREDS_PATH}`);
  console.log("=".repeat(60));
  return result;
}

// Background login state (used by the /v1/login endpoint, does not block HTTP).
let loginState = { status: "idle" };

async function startBackgroundLogin() {
  if (loginState.status === "pending") return loginState;
  const dev = await deviceAuth();
  loginState = {
    status: "pending",
    verification_uri: dev.url,
    user_code: dev.userCode,
    expires_in: dev.expiresIn,
    startedAt: new Date().toISOString(),
  };
  await announceAuth(dev);
  (async () => {
    try {
      const workos = await pollWorkOS(dev.deviceCode, dev.interval, dev.expiresIn);
      const result = await completeLogin(workos);
      loginState = { status: "ok", email: result.email, at: new Date().toISOString() };
      syncEnv(true);
      console.log("Login OK:", result.email);
    } catch (e) {
      loginState = { status: "error", error: String(e).slice(0, 300) };
      console.error("Login failed:", e);
    }
  })();
  return loginState;
}

// ===========================================================================
// opencode config auto-write
// ===========================================================================
// On startup, make sure the cline2api provider exists in the opencode config:
//   - config file missing        -> create it ($schema + provider.cline2api)
//   - exists, valid JSON         -> merge it in (preserve other fields; if
//                                   cline2api is already there, skip)
//   - exists, invalid JSON/jsonc -> skip and warn (never clobber)
// Target path priority: OPENCODE_CONFIG / OPENCODE_CONFIG_PATH env
//   -> existing opencode.json / opencode.jsonc ($XDG_CONFIG_HOME/opencode or
//      ~/.config/opencode)
//   -> default create ~/.config/opencode/opencode.json
// Set CLINE2API_NO_OPENCODE=1 to disable this entirely.

function opencodeConfigCandidates() {
  const base = process.env.XDG_CONFIG_HOME || path.join(HOME, ".config");
  const dir = path.join(base, "opencode");
  return [path.join(dir, "opencode.json"), path.join(dir, "opencode.jsonc")];
}

function buildOpencodeProvider(apiKey) {
  const host = HOST === "0.0.0.0" || HOST === "::" ? "127.0.0.1" : HOST;
  return {
    npm: "@ai-sdk/openai-compatible",
    name: "Cline2API (local)",
    options: {
      baseURL: `http://${host}:${PORT}/v1`,
      apiKey,
    },
    models: {
      "cline-free/deepseek-v4.1-flash": {
        name: "DeepSeek V4.1 Flash (free)",
        tool_call: true,
        reasoning: true,
        limit: { context: 128000, output: 32000 },
      },
      "cline-free/mimo-v2.6-flash": {
        name: "Mimo V2.6 Flash (free)",
        tool_call: true,
        reasoning: true,
      },
      "cline-free/muse-spark-1.3-contributor": {
        name: "Muse Spark 1.3 Contributor (free)",
        tool_call: true,
        reasoning: true,
      },
      "stealth/pixel-canary": {
        name: "Pixel Canary (free)",
        tool_call: true,
        reasoning: true,
      },
      "stealth/space-bunny-alpha": {
        name: "Space Bunny Alpha (free)",
        tool_call: true,
        reasoning: true,
      },
      "deepseek/deepseek-v4-flash": {
        name: "DeepSeek V4 Flash (free)",
        tool_call: true,
        reasoning: true,
      },
      "z-ai/glm-5.3-flash": {
        name: "GLM 5.3 Flash (free)",
        tool_call: true,
        reasoning: true,
      },
      "poolside/laguna-s-2.1:free": {
        name: "Laguna S 2.1 (free)",
        tool_call: true,
      },
      "qwen/qwen3.8-27b:free": {
        name: "Qwen3.8 27B (free)",
        tool_call: true,
        reasoning: true,
      },
      "nvidia/nemotron-3-super-120b-a12b:free": {
        name: "Nemotron 3 Super 120B (free)",
        tool_call: true,
        reasoning: true,
      },
    },
  };
}

function ensureOpencodeConfig() {
  if (SKIP_OPENCODE) return;
  try {
    let target = OPENCODE_CONFIG_PATH;
    let exists = false;
    if (target) {
      exists = fs.existsSync(target);
    } else {
      for (const c of opencodeConfigCandidates()) {
        if (fs.existsSync(c)) {
          target = c;
          exists = true;
          break;
        }
      }
      if (!target) {
        target = opencodeConfigCandidates()[0];
        exists = false;
      }
    }

    const apiKey = process.env.API_KEY || "cline2api-default-key";

    // Config file missing -> create it.
    if (!exists) {
      const cfg = {
        $schema: "https://opencode.ai/config.json",
        provider: { cline2api: buildOpencodeProvider(apiKey) },
      };
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, JSON.stringify(cfg, null, 2) + "\n");
      console.log("Created opencode config with the cline2api provider:");
      console.log("  " + target + "  (restart opencode to apply)");
      return;
    }

    // Already exists -> parse then merge (without overwriting other fields).
    let cfg;
    try {
      cfg = JSON.parse(fs.readFileSync(target, "utf8"));
    } catch (e) {
      console.warn("opencode config exists but is not valid JSON (comments/jsonc?); skipping auto-write:");
      console.warn("  " + target + "  -> please add the cline2api provider manually");
      return;
    }
    if (cfg && cfg.provider && cfg.provider.cline2api) {
      if (!FORCE_OPENCODE) {
        console.log("opencode config already has the cline2api provider; nothing to do: " + target);
        return;
      }
      // Force refresh: overwrite only the cline2api entry (keep other providers).
      cfg.provider.cline2api = buildOpencodeProvider(apiKey);
      cfg.$schema = cfg.$schema || "https://opencode.ai/config.json";
      fs.writeFileSync(target, JSON.stringify(cfg, null, 2) + "\n");
      console.log("Refreshed the cline2api provider (models/options) in the opencode config:");
      console.log("  " + target + "  (restart opencode to apply)");
      return;
    }
    cfg.$schema = cfg.$schema || "https://opencode.ai/config.json";
    cfg.provider = cfg.provider || {};
    cfg.provider.cline2api = buildOpencodeProvider(apiKey);
    fs.writeFileSync(target, JSON.stringify(cfg, null, 2) + "\n");
    console.log("Added the cline2api provider to the opencode config:");
    console.log("  " + target + "  (restart opencode to apply)");
  } catch (e) {
    console.warn("Failed to auto-write the opencode config (ignored):", String(e).slice(0, 200));
  }
}

// ===========================================================================
// Node req/res <-> Fetch Request/Response adaptation
// ===========================================================================

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

async function toFetchRequest(req) {
  const host = req.headers.host || `${HOST}:${PORT}`;
  const url = `http://${host}${req.url}`;
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (Array.isArray(v)) v.forEach((x) => headers.append(k, x));
    else if (v !== undefined) headers.set(k, v);
  }
  const method = (req.method || "GET").toUpperCase();
  const body = method === "GET" || method === "HEAD" ? undefined : await readBody(req);
  return new Request(url, { method, headers, body });
}

async function sendFetchResponse(res, response) {
  const headers = {};
  response.headers.forEach((v, k) => {
    headers[k] = v;
  });
  res.writeHead(response.status, headers);
  if (!response.body) {
    res.end();
    return;
  }
  const reader = response.body.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    const buf = Buffer.from(value);
    if (!res.write(buf)) await new Promise((r) => res.once("drain", r));
  }
  res.end();
}

function sendJson(res, obj, status = 200) {
  const body = JSON.stringify(obj, null, 2);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
  });
  res.end(body);
}

// ===========================================================================
// HTTP server
// ===========================================================================

async function handleRequest(req, res) {
  // Bare OPTIONS: reply with CORS directly.
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers":
        "Content-Type, Authorization, x-api-key, anthropic-version, anthropic-beta",
    });
    return res.end();
  }

  const pathname = (req.url || "/").split("?")[0];

  // Login endpoints (local extension)
  if (req.method === "GET" && pathname === "/v1/login") {
    try {
      const st = await startBackgroundLogin();
      return sendJson(res, st);
    } catch (e) {
      return sendJson(res, { status: "error", error: String(e).slice(0, 300) }, 500);
    }
  }
  if (req.method === "GET" && pathname === "/v1/login/status") {
    return sendJson(res, loginState);
  }
  if (req.method === "GET" && pathname === "/") {
    const tokens = syncEnv(true);
    return sendJson(res, {
      name: "cline2api-local",
      version: VERSION,
      status: "ok",
      accounts: tokens.length,
      token_sources: {
        env: ENV_REFRESH_TOKENS.length > 0,
        providers_file: PROVIDERS_PATH,
        local_creds_file: LOCAL_CREDS_PATH,
      },
      endpoints: ["/v1/health", "/v1/models", "/v1/chat/completions", "/v1/messages", "/v1/login", "/v1/login/status"],
    });
  }

  // Everything else goes to the Cline request handler.
  try {
    syncEnv(false); // hot reload: reload tokens if the files changed
    const fetchReq = await toFetchRequest(req);
    const fetchRes = await clineFetchHandler(fetchReq, {
      CLINE_REFRESH_TOKEN: process.env.CLINE_REFRESH_TOKEN || "",
      API_KEY: process.env.API_KEY || "",
    });
    await sendFetchResponse(res, fetchRes);
  } catch (e) {
    console.error("[server] request error:", e);
    if (!res.headersSent) sendJson(res, { error: { message: String(e) } }, 500);
    else res.end();
  }
}

async function main() {
  if (LOGIN_MODE) {
    await runLoginInteractive();
    process.exit(0);
  }

  const tokens = syncEnv(true);
  console.log("cline2api-local v" + VERSION);
  console.log("  providers.json : " + PROVIDERS_PATH);
  console.log("  credentials    : " + LOCAL_CREDS_PATH);

  if (tokens.length === 0) {
    console.warn("No refreshToken found.");
    if (AUTO_LOGIN) {
      console.log("-> Starting the device authorization flow automatically...\n");
      try {
        await startBackgroundLogin();
      } catch (e) {
        console.error("Failed to start auto login:", e);
      }
    } else {
      console.warn("-> Run `node server.js --login` or open GET /v1/login to sign in.");
    }
  } else {
    console.log(`Loaded ${tokens.length} account(s) (Cline CLI config / local creds / env)`);
  }

  // Make sure the opencode config has the cline2api provider (create if missing, skip if present).
  ensureOpencodeConfig();

  const server = http.createServer((req, res) => {
    handleRequest(req, res).catch((e) => {
      console.error("[server] uncaught error:", e);
      try {
        if (!res.headersSent) sendJson(res, { error: { message: String(e) } }, 500);
        else res.end();
      } catch (e2) {}
    });
  });

  server.listen(PORT, HOST, () => {
    console.log(`\nLocal API listening on http://${HOST}:${PORT}/v1`);
    console.log(`  health: curl http://${HOST}:${PORT}/v1/health`);
    console.log(`  models: curl http://${HOST}:${PORT}/v1/models`);
    console.log("  (token files are hot-reloaded; no restart needed)\n");
  });

  const shutdown = () => {
    console.log("\nShutting down...");
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1500).unref();
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

// Only start the server when executed directly; when required, the helpers below
// are exposed for testing.
module.exports = { getTokens, syncEnv, saveLocalToken, tokensFromProviders, tokensFromLocal };

if (require.main === module) {
  main().catch((e) => {
    console.error("Startup failed:", e);
    process.exit(1);
  });
}
