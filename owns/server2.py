#!/usr/bin/env python3
"""
WorkBuddy2API - Single-file OpenAI-compatible REST server for WorkBuddy / CodeBuddy.
====================================================================================
Exposes WorkBuddy's DeepSeek chat models through a standard OpenAI API so any
OpenAI-compatible client (Claude Code, SDKs, scripts, etc.) can use them.

Endpoints:
  POST /v1/chat/completions   OpenAI-compatible chat completions (SSE streaming supported)
  GET  /v1/models             List the supported DeepSeek models
  GET  /health                Health check

CLI actions:
  --login                     Sign in via the WorkBuddy device-login flow and save a token
  --setup-opencode            Register this server as a custom provider in the OpenCode config

Environment variables:
  CODEBUDDY_AUTH_TOKEN   (optional) WorkBuddy / CodeBuddy Bearer token; or use `--login`
  API_KEY                (required) API key required to call this server
  DEFAULT_MODEL          (optional) Default model, default: deepseek-v4.1-flash
  DEFAULT_THINKING       (optional) Default reasoning depth, default: high
  DEFAULT_SYSTEM_PROMPT  (optional) System prompt injected when a request has none
  PORT                   (optional) Listen port, default: 8000
  MAX_TOKENS_DEFAULT     (optional) Default max_tokens, default: 8192
  CODEBUDDY_API_BASE     (optional) Upstream base URL, default: https://www.workbuddy.ai

Example:
  curl http://localhost:8000/v1/chat/completions \\
    -H "Authorization: Bearer $API_KEY" \\
    -H "Content-Type: application/json" \\
    -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"Hello"}]}'
"""

from __future__ import annotations

import os
import sys
import json
import time
import base64
import random
import uuid
import asyncio
import threading
import traceback
import argparse
import webbrowser
import http.client
import ssl
import re
import urllib.request
import urllib.error
from typing import Optional
from urllib.parse import urlparse
from contextlib import asynccontextmanager

# -- Upstream constants --------------------------------------------------------
# Global (.ai) accounts serve chat on the WorkBuddy web host; China (.cn) accounts
# use copilot.tencent.com. Override with CODEBUDDY_API_BASE.
_API_BASE_ENV = os.environ.get("CODEBUDDY_API_BASE")
DEFAULT_API_BASE = _API_BASE_ENV or "https://www.workbuddy.ai"
DEFAULT_AUTH_FILE = os.path.expanduser(
    "~/Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info"
)
CHAT_COMPLETIONS_PATH = "/v2/chat/completions"
TOKEN_REFRESH_PATH = "/v2/plugin/auth/token/refresh"

AUTH_FILE_PATHS = [
    DEFAULT_AUTH_FILE,
    os.path.expanduser("~/.workbuddy/auth/workbuddy-desktop.info"),
    os.path.expanduser("~/.config/workbuddy/auth/workbuddy-desktop.info"),
]

# Fixed User-Agent used only for the upstream config endpoint.
CONFIG_UA = "WorkBuddy/0.0.0"

# -- Login / OAuth constants ---------------------------------------------------
# Web base used for the device-login flow. WorkBuddy and CodeBuddy are the same
# Tencent platform (workbuddy.ai / workbuddy.cn / codebuddy.cn / copilot.tencent
# .com all share the gateway and the /v2/plugin/auth endpoints), so a token from
# any of them works for the others. Defaults to the global www.workbuddy.ai login
# (Google / Apple / WeChat / QQ) instead of the China-only Tencent ID flow.
# Override with --base or CODEBUDDY_WEB_BASE (e.g. https://www.workbuddy.cn).
CODEBUDDY_WEB_BASE = os.environ.get("CODEBUDDY_WEB_BASE", "https://www.workbuddy.ai")
# Where a token obtained via `--login` is persisted (works on any OS, incl. Linux).
TOKEN_FILE = os.environ.get(
    "CODEBUDDY_TOKEN_FILE",
    os.path.expanduser("~/.workbuddy2api/token.json"),
)
# The active token file, if the loaded token came from TOKEN_FILE (so refreshes persist).
_active_token_file: str | None = None

# Default OpenCode config path (global). Override with --opencode-path.
OPENCODE_DEFAULT_CONFIG = os.path.expanduser("~/.config/opencode/opencode.json")

# -- Model registry (DeepSeek only) --------------------------------------------
# Model ids exposed by the global WorkBuddy (.ai) lineup. `deepseek-v4.1-flash`
# is the DeepSeek flagship: 1M context window, native multimodal, reasoning +
# tool calling, and it is FREE (x0.00 credits). `-sg` is the Singapore region
# variant (x0.03 credits). Verify with: GET /v3/config (upstream).
KNOWN_CHAT_MODELS = {
    "deepseek-v4.1-flash",
    "deepseek-v4.1-flash-sg",
}

# Models that consume no credits (free tier), per the upstream model metadata.
FREE_MODELS = {
    "deepseek-v4.1-flash",
}

# DeepSeek models verified to accept the reasoning_effort parameter.
THINKING_CAPABLE_MODELS = {
    "deepseek-v4.1-flash",
    "deepseek-v4.1-flash-sg",
}

# Display metadata used when generating the OpenCode provider (see --setup-opencode).
OPENCODE_MODEL_METADATA = {
    "deepseek-v4.1-flash": {"name": "DeepSeek V4.1 Flash", "context": 1000000, "output": 128000},
    "deepseek-v4.1-flash-sg": {"name": "DeepSeek V4.1 Flash (SG)", "context": 1000000, "output": 128000},
}

# reasoning_effort values: max -> deepest, high -> deep (default), medium ->
# balanced, low -> fast, off -> disabled.
THINKING_LEVELS = {
    "off": "none",
    "low": "low",
    "medium": "medium",
    "high": "high",
    "max": "max",
}
DEFAULT_THINKING = "high"

# The upstream API requires the first message to be a system prompt. When a
# request does not start with one, this prompt is injected automatically.
DEFAULT_SYSTEM_PROMPT = os.environ.get(
    "DEFAULT_SYSTEM_PROMPT", "You are a helpful assistant."
)

# -- Safety / anti-ban configuration ------------------------------------------
MIN_REQUEST_INTERVAL = 1.5   # Minimum seconds between requests
SAFE_MODE_INTERVAL = 6.0     # Longer interval in safe mode
MAX_RETRIES = 3
BACKOFF_BASE = 2.0
MAX_BACKOFF = 30.0


# -- Rate limiter --------------------------------------------------------------
class RateLimiter:
    """Simple thread-safe request rate limiter."""

    def __init__(self, min_interval: float = MIN_REQUEST_INTERVAL):
        self.min_interval = min_interval
        self._last_request_time = 0.0
        self._lock = threading.Lock()
        self._request_count = 0

    def wait(self) -> float:
        """Block until the next request may be sent; return the slept seconds."""
        with self._lock:
            now = time.time()
            elapsed = now - self._last_request_time
            sleep_time = self.min_interval - elapsed if elapsed < self.min_interval else 0.0
            # Small random jitter to mimic human pacing.
            jitter = random.uniform(-0.3, 0.3)
            total_sleep = max(0.0, sleep_time + jitter)
            if total_sleep > 0:
                time.sleep(total_sleep)
            self._last_request_time = time.time()
            self._request_count += 1
            return total_sleep


# -- JWT helpers ---------------------------------------------------------------
def decode_jwt_payload(token: str) -> dict | None:
    """Decode a JWT payload without verifying the signature."""
    try:
        parts = token.split(".")
        if len(parts) < 2:
            return None
        payload_b64 = parts[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        payload_json = base64.urlsafe_b64decode(payload_b64)
        return json.loads(payload_json)
    except Exception:
        return None


def jwt_is_expired(token: str, margin_seconds: int = 300) -> bool:
    """Return True if the JWT is expired or expires within margin_seconds."""
    claims = decode_jwt_payload(token)
    if not claims or "exp" not in claims:
        return True
    return time.time() + margin_seconds >= claims["exp"]


def jwt_get_user_id(token: str) -> str | None:
    claims = decode_jwt_payload(token)
    return claims.get("sub") if claims else None


def jwt_get_domain(token: str) -> str | None:
    claims = decode_jwt_payload(token)
    iss = claims.get("iss", "") if claims else ""
    try:
        return urlparse(iss).hostname
    except Exception:
        return None


# -- Token management ----------------------------------------------------------
def extract_token_from_auth_file(filepath: str) -> dict | None:
    """Extract token information from a WorkBuddy desktop auth file."""
    try:
        with open(filepath, "r") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

    auth = data.get("auth", {})
    account = data.get("account", {})
    if not auth.get("accessToken"):
        return None

    return {
        "access_token": auth["accessToken"],
        "refresh_token": auth.get("refreshToken", ""),
        "token_type": auth.get("tokenType", "Bearer"),
        "expires_at": auth.get("expiresAt", 0) / 1000,
        "refresh_expires_at": auth.get("refreshExpiresAt", 0) / 1000,
        "domain": auth.get("domain", ""),
        "user_id": account.get("uid", ""),
        "nickname": account.get("nickname", ""),
        "enterprise_id": account.get("enterpriseId", ""),
        "account_type": account.get("type", "personal"),
    }


def find_and_load_token(auth_file_override: str | None = None) -> dict:
    """Load a token by priority: env var > explicit file > saved login file > default paths."""
    global _active_token_file

    env_token = os.environ.get("CODEBUDDY_AUTH_TOKEN")
    if env_token:
        _active_token_file = None
        return {
            "access_token": env_token,
            "refresh_token": "",
            "token_type": "Bearer",
            "expires_at": 0,
            "refresh_expires_at": 0,
            "domain": jwt_get_domain(env_token) or "www.workbuddy.ai",
            "user_id": jwt_get_user_id(env_token) or "",
            "nickname": "",
            "enterprise_id": "",
            "account_type": "personal",
        }

    if auth_file_override:
        result = extract_token_from_auth_file(auth_file_override)
        if result:
            _active_token_file = auth_file_override
            return result
        print(f"[!] Invalid auth file: {auth_file_override}", file=sys.stderr)

    # Token saved by `--login` (the cross-platform / Linux path).
    saved = load_token_file()
    if saved:
        _active_token_file = TOKEN_FILE
        return saved

    for path in AUTH_FILE_PATHS:
        result = extract_token_from_auth_file(path)
        if result:
            _active_token_file = None
            return result

    raise RuntimeError(
        "Unable to obtain a token. Please:\n"
        "  1. Set the CODEBUDDY_AUTH_TOKEN environment variable, or\n"
        "  2. Run `python server.py --login` to sign in, or\n"
        "  3. Ensure WorkBuddy is logged in (auth file paths: {})".format(
            " | ".join(AUTH_FILE_PATHS)
        )
    )


# -- Login / OAuth helpers -----------------------------------------------------
def save_token_file(token_info: dict, path: str | None = None) -> None:
    """Persist token information to disk (owner-readable only)."""
    path = path or TOKEN_FILE
    try:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(token_info, f, ensure_ascii=False, indent=2)
        os.chmod(path, 0o600)
        print(f"[+] Token saved to {path}", file=sys.stderr)
    except OSError as e:
        print(f"[!] Failed to write token file: {e}", file=sys.stderr)


def load_token_file(path: str | None = None) -> dict | None:
    """Load token information from disk, if present."""
    path = path or TOKEN_FILE
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("access_token"):
            return data
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return None


def _oauth_headers(base_url: str) -> dict:
    """Headers for the CodeBuddy OAuth endpoints, matching the real CLI."""
    host = urlparse(base_url).hostname or "www.workbuddy.ai"
    request_id = uuid.uuid4().hex
    span_id = uuid.uuid4().hex[:16]
    return {
        "Accept": "application/json, text/plain, */*",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
        "Connection": "close",
        "X-Requested-With": "XMLHttpRequest",
        "X-Domain": host,
        "X-No-Authorization": "true",
        "X-No-User-Id": "true",
        "X-No-Enterprise-Id": "true",
        "X-No-Department-Info": "true",
        "User-Agent": "CLI/1.0.8 CodeBuddy/1.0.8",
        "X-Product": "SaaS",
        "X-Request-ID": request_id,
        "b3": f"{request_id}-{span_id}-1-",
        "X-B3-TraceId": request_id,
        "X-B3-SpanId": span_id,
        "X-B3-Sampled": "1",
    }


def _http_json(method: str, url: str, headers: dict, body: dict | None = None,
               timeout: int = 20) -> tuple[int, dict]:
    """Small JSON HTTP helper built on the standard library (urllib)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw}


def do_login(base_url: str = CODEBUDDY_WEB_BASE, platform: str = "CLI",
             open_browser: bool = True, timeout: int = 300) -> int:
    """Obtain a token via the WorkBuddy/CodeBuddy device-login flow.

    1. Ask the server for a ``state`` and ``authUrl``.
    2. Ask the user to open ``authUrl`` and sign in.
    3. Poll ``/v2/plugin/auth/token`` until the tokens are issued, then save them.

    This works on Linux (and any OS) with no desktop client.
    """
    print(f"[*] Starting WorkBuddy login against {base_url} (platform={platform})",
          file=sys.stderr)

    nonce = uuid.uuid4().hex
    state_url = f"{base_url}/v2/plugin/auth/state?platform={platform}&nonce={nonce}"
    headers = _oauth_headers(base_url)
    headers["Content-Type"] = "application/json"

    try:
        _, payload = _http_json("POST", state_url, headers, body={"nonce": nonce})
    except Exception as e:
        print(f"[!] Failed to start login: {e}", file=sys.stderr)
        return 1

    data = payload.get("data") or {}
    state = data.get("state")
    auth_url = data.get("authUrl") or data.get("auth_url")
    if payload.get("code") != 0 or not state or not auth_url:
        print(f"[!] Unexpected /auth/state response: {payload}", file=sys.stderr)
        return 1

    print()
    print("  Open this URL in your browser and log in (Google / Apple / WeChat / QQ):")
    print()
    print(f"    {auth_url}")
    print()
    if open_browser:
        try:
            webbrowser.open(auth_url)
        except Exception:
            pass

    token_url = f"{base_url}/v2/plugin/auth/token?state={state}"
    deadline = time.time() + timeout
    print("[*] Waiting for you to complete the login...", file=sys.stderr)

    while time.time() < deadline:
        time.sleep(2)
        try:
            _, payload = _http_json("GET", token_url, _oauth_headers(base_url))
        except Exception as e:
            print(f"[!] Poll error: {e}", file=sys.stderr)
            continue

        code = payload.get("code")
        if code == 11217:  # login still in progress
            continue
        if code == 0 and (payload.get("data") or {}).get("accessToken"):
            d = payload["data"]
            access = d["accessToken"]
            expires_in = d.get("expiresIn") or 0
            token_info = {
                "access_token": access,
                "refresh_token": d.get("refreshToken", ""),
                "token_type": d.get("tokenType", "Bearer"),
                "expires_at": (time.time() + expires_in) if expires_in else 0,
                "refresh_expires_at": 0,
                "domain": d.get("domain") or jwt_get_domain(access) or "www.workbuddy.ai",
                "user_id": jwt_get_user_id(access) or "",
                "nickname": "",
                "enterprise_id": d.get("enterpriseId") or d.get("enterprise_id") or "",
                "tenant_id": d.get("tenantId") or d.get("tenant_id") or "",
                "scope": d.get("scope", ""),
                "account_type": "personal",
            }
            print("[+] Login successful", file=sys.stderr)
            save_token_file(token_info)
            return 0

        print(f"[!] Login failed: {payload.get('msg') or payload}", file=sys.stderr)
        return 1

    print("[!] Timed out waiting for login", file=sys.stderr)
    return 1


# -- OpenCode integration ------------------------------------------------------
def _argv_value(argv: list[str], flag: str, default: str | None = None) -> str | None:
    """Return the value following ``flag`` in ``argv`` (used for early dispatch)."""
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def _strip_jsonc(text: str) -> str:
    """Convert JSONC (comments + trailing commas) into plain JSON text."""
    out: list[str] = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def _load_opencode_config(path: str) -> dict:
    """Load an OpenCode config (JSON or JSONC); return {} when the file is absent."""
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        data = json.loads(_strip_jsonc(text))
    if not isinstance(data, dict):
        raise ValueError("config root must be a JSON object")
    return data


def build_opencode_provider(base_url: str, api_key: str | None) -> dict:
    """Build the OpenCode custom-provider block for this server."""
    models: dict = {}
    for model_id in sorted(KNOWN_CHAT_MODELS):
        meta = OPENCODE_MODEL_METADATA.get(model_id, {})
        entry: dict = {"name": meta.get("name", model_id)}
        if meta.get("context") and meta.get("output"):
            entry["limit"] = {"context": meta["context"], "output": meta["output"]}
        models[model_id] = entry
    return {
        "npm": "@ai-sdk/openai-compatible",
        "name": "WorkBuddy",
        "options": {
            "baseURL": base_url,
            "apiKey": api_key or "{env:WORKBUDDY_API_KEY}",
        },
        "models": models,
    }


def setup_opencode(
    path: str,
    provider_id: str = "workbuddy",
    base_url: str | None = None,
    api_key: str | None = None,
    force: bool = False,
) -> int:
    """Register this server as a custom provider in the OpenCode config.

    Idempotent: everything else in the config is preserved, and when the
    provider id is already present the file is left untouched unless ``force``
    is set. Returns a process exit code.
    """
    path = os.path.expanduser(path)
    base_url = base_url or f"http://localhost:{os.environ.get('PORT', '8000')}/v1"

    try:
        config = _load_opencode_config(path)
    except Exception as e:
        print(f"[!] Cannot read {path}: {e}", file=sys.stderr)
        return 3

    config.setdefault("$schema", "https://opencode.ai/config.json")
    providers = config.setdefault("provider", {})
    if not isinstance(providers, dict):
        print(f"[!] 'provider' in {path} is not a JSON object", file=sys.stderr)
        return 3

    if provider_id in providers and not force:
        print(f"[=] Provider '{provider_id}' is already configured in {path}")
        print("    Nothing changed. Use --force to overwrite it.")
        return 0

    existed = provider_id in providers
    providers[provider_id] = build_opencode_provider(base_url, api_key)

    try:
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(config, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
    except Exception as e:
        print(f"[!] Cannot write {path}: {e}", file=sys.stderr)
        return 3

    print(f"[+] Provider '{provider_id}' {'updated' if existed else 'added'} in {path}")
    print(f"    baseURL : {base_url}")
    print(f"    models  : {', '.join(sorted(KNOWN_CHAT_MODELS))}")
    print("    Next steps:")
    print(f"      1. opencode auth login   # choose 'Other' and use provider id '{provider_id}'")
    print("         (or export WORKBUDDY_API_KEY and keep the {env:WORKBUDDY_API_KEY} placeholder)")
    print("      2. select a model in OpenCode with /models")
    return 0


def _early_login_dispatch() -> None:
    """Handle ``--login`` and ``--setup-opencode`` before importing FastAPI.

    Both actions only touch the local filesystem, so they must work even when
    the server dependencies (fastapi/uvicorn) are not installed.
    """
    argv = sys.argv[1:]

    if "--setup-opencode" in argv:
        sys.exit(setup_opencode(
            path=(_argv_value(argv, "--opencode-path", None) or OPENCODE_DEFAULT_CONFIG),
            provider_id=(_argv_value(argv, "--opencode-provider", None) or "workbuddy"),
            base_url=_argv_value(argv, "--opencode-base-url", None),
            api_key=_argv_value(argv, "--opencode-api-key", None),
            force="--force" in argv,
        ))

    if "--login" not in argv:
        # If FastAPI is not installed, still offer a minimal --help so the
        # filesystem-only actions stay discoverable.
        if any(a in ("-h", "--help") for a in argv):
            import importlib.util
            if importlib.util.find_spec("fastapi") is None:
                print(
                    "WorkBuddy2API\n"
                    "  python server.py --login            # sign in and save a token (no deps needed)\n"
                    "  python server.py --setup-opencode   # add the provider to OpenCode (no deps needed)\n"
                    "  python server.py                    # start the API server\n"
                    "\n"
                    "The API server needs: pip install fastapi uvicorn"
                )
                sys.exit(0)
        return

    base = CODEBUDDY_WEB_BASE
    platform = "CLI"
    timeout = 300
    open_browser = True
    for i, arg in enumerate(argv):
        if arg == "--base" and i + 1 < len(argv):
            base = argv[i + 1]
        elif arg == "--platform" and i + 1 < len(argv):
            platform = argv[i + 1]
        elif arg == "--login-timeout" and i + 1 < len(argv):
            try:
                timeout = int(argv[i + 1])
            except ValueError:
                pass
        elif arg == "--no-browser":
            open_browser = False

    sys.exit(do_login(base, platform, open_browser=open_browser, timeout=timeout))


if __name__ == "__main__":
    _early_login_dispatch()


# -- Upstream HTTP client ------------------------------------------------------
class ApiClient:
    """Lightweight HTTP client for the WorkBuddy upstream API.

    Includes simple anti-ban measures: request rate limiting and retry with
    exponential backoff.
    """

    def __init__(self, base_url: str, token_info: dict, safe_mode: bool = False):
        self.base_url = base_url.rstrip("/")
        self.token_info = token_info
        self._conn: http.client.HTTPSConnection | None = None
        interval = SAFE_MODE_INTERVAL if safe_mode else MIN_REQUEST_INTERVAL
        self.rate_limiter = RateLimiter(min_interval=interval)
        # Session-level 32-char hex ID (no dashes), mirroring the real client UUID.
        self._session_id = uuid.uuid4().hex
        # Session-level trace ID.
        self._trace_id = uuid.uuid4().hex[:32]
        # Latest conversationId extracted from the SSE stream.
        self._conversation_id: str | None = None

    @property
    def hostname(self) -> str:
        return urlparse(self.base_url).hostname or ""

    def _get_connection(self) -> http.client.HTTPSConnection:
        if self._conn is None:
            ctx = ssl.create_default_context()
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            self._conn = http.client.HTTPSConnection(
                self.hostname, 443, context=ctx, timeout=90
            )
        return self._conn

    def _reset_connection(self):
        if self._conn:
            try:
                self._conn.close()
            except Exception:
                pass
            self._conn = None

    def _build_headers(self, extra: dict | None = None, stream: bool = False,
                       model: str = "") -> dict:
        """Build request headers matching the real WorkBuddy client."""
        headers = {
            "Authorization": f"Bearer {self.token_info['access_token']}",
            "X-User-Id": self.token_info.get("user_id", ""),
            "X-Product": "SaaS",
            "X-Request-ID": self._session_id,
            "X-Trace-ID": self._trace_id,
            "Content-Type": "application/json",
            "Accept": "text/event-stream" if stream else "application/json",
        }
        if model:
            headers["X-Model-ID"] = model
        if self.token_info.get("enterprise_id"):
            headers["X-Enterprise-Id"] = self.token_info["enterprise_id"]
            headers["X-Tenant-Id"] = self.token_info["enterprise_id"]
        elif self.token_info.get("tenant_id"):
            headers["X-Tenant-Id"] = self.token_info["tenant_id"]
        if self.token_info.get("domain"):
            headers["X-Domain"] = self.token_info["domain"]
        if extra:
            headers.update(extra)
        return headers

    def refresh_token(self) -> bool:
        """Refresh the access token using the refresh token (not rate limited)."""
        refresh_token = self.token_info.get("refresh_token")
        if not refresh_token:
            print("[!] No refresh_token available; cannot refresh", file=sys.stderr)
            return False

        print("[*] Refreshing token...", file=sys.stderr)
        try:
            conn = self._get_connection()
            headers = {
                "Authorization": f"Bearer {self.token_info['access_token']}",
                "X-Refresh-Token": refresh_token,
                "X-User-Id": self.token_info.get("user_id", ""),
                "X-Auth-Refresh-Source": "plugin",
                "X-Request-ID": self._session_id,
                "X-Product": "SaaS",
            }
            if self.token_info.get("domain"):
                headers["X-Domain"] = self.token_info["domain"]

            conn.request("POST", TOKEN_REFRESH_PATH, body="{}", headers=headers)
            resp = conn.getresponse()
            body = resp.read().decode("utf-8")
            self._reset_connection()

            if resp.status != 200:
                print(f"[!] Token refresh failed: {resp.status} {body[:500]}", file=sys.stderr)
                return False

            data = json.loads(body)
            auth_data = data.get("data", data)

            new_access = auth_data.get("accessToken") or auth_data.get("access_token")
            new_refresh = auth_data.get("refreshToken") or auth_data.get("refresh_token")

            if new_access:
                self.token_info["access_token"] = new_access
                expires_in = auth_data.get("expiresIn", 0) or 0
                self.token_info["expires_at"] = (
                    expires_in / 1000 + time.time() if isinstance(expires_in, (int, float)) else 0
                )
            if new_refresh:
                self.token_info["refresh_token"] = new_refresh
                refresh_expires_in = auth_data.get("refreshExpiresIn", 0) or 0
                self.token_info["refresh_expires_at"] = (
                    refresh_expires_in / 1000 + time.time()
                    if isinstance(refresh_expires_in, (int, float)) else 0
                )

            print("[+] Token refreshed successfully", file=sys.stderr)
            if _active_token_file:
                save_token_file(self.token_info, _active_token_file)
            return True

        except Exception as e:
            self._reset_connection()
            print(f"[!] Token refresh error: {e}", file=sys.stderr)
            return False

    def ensure_valid_token(self) -> bool:
        """Ensure the access token is valid, refreshing it when expired."""
        if not jwt_is_expired(self.token_info["access_token"]):
            return True
        print("[!] Access token expired, attempting refresh...", file=sys.stderr)
        if self.refresh_token():
            return True
        raise RuntimeError("Token expired and refresh failed. Please log in to WorkBuddy again.")

    def chat_completion(
        self,
        messages: list[dict],
        model: str = "deepseek-v4.1-flash",
        temperature: float = 0.7,
        max_tokens: int = 8192,
        stream: bool = True,
        thinking_level: str | None = None,
        tools: list[dict] | None = None,
        tool_choice: str | dict | None = None,
    ) -> dict | None:
        """Send a chat request.

        Returns {"content": str, "reasoning_content": str, "tool_calls": list,
        "finish_reason": str} or None on failure.

        Args:
            thinking_level: reasoning depth - "off"|"low"|"medium"|"high"|"max".
                None means use the model default.
            tools: OpenAI-style tools list [{"type": "function", "function": {...}}].
            tool_choice: "auto"|"none"|"required"|{"type": "function", ...}.
        """
        self.ensure_valid_token()

        body: dict = {
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": stream,
        }

        # Echo the conversationId back to upstream (real client behaviour).
        if self._conversation_id:
            body["conversationId"] = self._conversation_id

        # Reasoning depth: enable the deepest level by default for capable models.
        if model in THINKING_CAPABLE_MODELS:
            if thinking_level is None:
                thinking_level = DEFAULT_THINKING
            effort = THINKING_LEVELS.get(thinking_level, THINKING_LEVELS[DEFAULT_THINKING])
            body["reasoning_effort"] = effort

        if tools:
            body["tools"] = tools
        if tool_choice is not None:
            body["tool_choice"] = tool_choice

        headers = self._build_headers(stream=stream, model=model)

        # Rate limiting: wait for the safe interval.
        self.rate_limiter.wait()

        last_error = None
        for attempt in range(MAX_RETRIES):
            try:
                conn = self._get_connection()
                conn.request(
                    "POST", CHAT_COMPLETIONS_PATH,
                    body=json.dumps(body), headers=headers,
                )
                resp = conn.getresponse()

                # 401 -> refresh token and retry.
                if resp.status == 401 and attempt < MAX_RETRIES - 1:
                    error_body = resp.read(2048).decode("utf-8", errors="replace")
                    self._reset_connection()
                    print("[!] Received 401, refreshing token and retrying...", file=sys.stderr)
                    if self.refresh_token():
                        headers = self._build_headers(stream=stream, model=model)
                        continue
                    print(f"[!] 401 body: {error_body[:300]}", file=sys.stderr)
                    break

                # 429 -> exponential backoff.
                if resp.status == 429:
                    self._reset_connection()
                    backoff = min(BACKOFF_BASE ** (attempt + 1) + random.uniform(0, 2), MAX_BACKOFF)
                    print(f"[!] Received 429 (rate limited), backing off {backoff:.1f}s...",
                          file=sys.stderr)
                    time.sleep(backoff)
                    continue

                if resp.status != 200:
                    error_body = resp.read(2048).decode("utf-8", errors="replace")
                    self._reset_connection()

                    # 5xx -> retry with exponential backoff.
                    if resp.status >= 500 and attempt < MAX_RETRIES - 1:
                        backoff = min(BACKOFF_BASE ** (attempt + 1) + random.uniform(0, 1), MAX_BACKOFF)
                        print(f"[!] Server error {resp.status}, retrying in {backoff:.1f}s "
                              f"({attempt + 1}/{MAX_RETRIES})...", file=sys.stderr)
                        time.sleep(backoff)
                        continue

                    print(f"[!] API error {resp.status}: {error_body[:500]}", file=sys.stderr)
                    last_error = f"{resp.status}: {error_body[:200]}"
                    return None

                if stream:
                    return self._parse_sse_stream(resp)

                data = json.loads(resp.read().decode("utf-8"))
                self._reset_connection()
                choices = data.get("choices", [])
                if choices:
                    message = choices[0].get("message", {})
                    return {
                        "content": message.get("content", ""),
                        "reasoning_content": message.get("reasoning_content", ""),
                        "tool_calls": message.get("tool_calls"),
                        "finish_reason": choices[0].get("finish_reason", "stop"),
                    }
                return None

            except (http.client.HTTPException, ConnectionError, OSError, TimeoutError) as e:
                self._reset_connection()
                last_error = str(e)
                if attempt < MAX_RETRIES - 1:
                    backoff = min(BACKOFF_BASE ** (attempt + 1) + random.uniform(0, 1), MAX_BACKOFF)
                    print(f"[!] Connection error, retrying in {backoff:.1f}s "
                          f"({attempt + 1}/{MAX_RETRIES}): {e}", file=sys.stderr)
                    time.sleep(backoff)
                    continue
                print(f"[!] Request failed: {e}", file=sys.stderr)
                return None

        if last_error:
            print(f"[!] All retries failed. Last error: {last_error}", file=sys.stderr)
        return None

    def _parse_sse_stream(self, resp: http.client.HTTPResponse) -> dict | None:
        """Parse an SSE response stream.

        Returns {"content", "reasoning_content", "tool_calls", "finish_reason"} or None.
        Streamed reasoning_content, content and tool_calls are accumulated separately.
        The conversationId is extracted and stored for reuse in later requests.
        """
        full_text = ""
        thinking_text = ""
        finish_reason = "stop"
        current_event = ""
        tool_calls_acc: dict[int, dict] = {}

        try:
            buffer = b""
            while True:
                chunk = resp.read(4096)
                if not chunk:
                    break
                buffer += chunk

                while b"\n" in buffer:
                    line_end = buffer.index(b"\n")
                    line = buffer[:line_end].decode("utf-8", errors="replace").strip()
                    buffer = buffer[line_end + 1:]

                    if not line or line.startswith(":"):
                        continue

                    if line.startswith("event:"):
                        current_event = line[6:].strip()
                        continue

                    if line.startswith("data:"):
                        data_str = line[5:].strip()

                        if current_event == "conversationId":
                            if data_str.startswith("conv-"):
                                self._conversation_id = data_str
                            current_event = ""
                            continue

                        if data_str == "[DONE]":
                            break

                        try:
                            data = json.loads(data_str)
                            choices = data.get("choices", [])
                            if choices:
                                delta = choices[0].get("delta", {})
                                content = delta.get("content", "")
                                reasoning = delta.get("reasoning_content", "")
                                tool_calls = delta.get("tool_calls")

                                if tool_calls:
                                    for tc in tool_calls:
                                        idx = tc.get("index", 0)
                                        if idx not in tool_calls_acc:
                                            tool_calls_acc[idx] = {
                                                "index": idx,
                                                "id": None,
                                                "type": "function",
                                                "function": {"name": None, "arguments": ""},
                                            }
                                        acc = tool_calls_acc[idx]
                                        if tc.get("id"):
                                            acc["id"] = tc["id"]
                                        if tc.get("type"):
                                            acc["type"] = tc["type"]
                                        if tc.get("function", {}).get("name"):
                                            acc["function"]["name"] = tc["function"]["name"]
                                        if tc.get("function", {}).get("arguments"):
                                            acc["function"]["arguments"] += tc["function"]["arguments"]

                                if reasoning:
                                    thinking_text += reasoning
                                if content:
                                    full_text += content

                                finish_reason = choices[0].get("finish_reason", finish_reason)
                        except json.JSONDecodeError:
                            pass

                        current_event = ""

        finally:
            self._reset_connection()

        if not full_text and thinking_text:
            full_text = thinking_text

        if not full_text and not thinking_text and not tool_calls_acc:
            return None

        result = {
            "content": full_text,
            "reasoning_content": thinking_text,
            "finish_reason": finish_reason,
        }
        if tool_calls_acc:
            result["tool_calls"] = [tool_calls_acc[i] for i in sorted(tool_calls_acc)]
        return result


# -- FastAPI application -------------------------------------------------------
try:
    from fastapi import FastAPI, Request, HTTPException
    from fastapi.responses import StreamingResponse, JSONResponse
    from fastapi.middleware.cors import CORSMiddleware
except ImportError:
    print("Please install dependencies: pip install fastapi uvicorn", file=sys.stderr)
    sys.exit(1)

# -- Server configuration ------------------------------------------------------
API_KEY = os.environ.get("API_KEY", "")
CODEBUDDY_AUTH_TOKEN = os.environ.get("CODEBUDDY_AUTH_TOKEN", "")
DEFAULT_MODEL = os.environ.get("DEFAULT_MODEL", "deepseek-v4.1-flash")
DEFAULT_THINKING_ENV = os.environ.get("DEFAULT_THINKING", DEFAULT_THINKING)
MAX_TOKENS_DEFAULT = int(os.environ.get("MAX_TOKENS_DEFAULT", "8192"))
PORT = int(os.environ.get("PORT", "8000"))

if not API_KEY:
    print("[!] API_KEY is not set; the API will be unprotected", file=sys.stderr)
    print("[!] Set API_KEY and restart", file=sys.stderr)

_client_singleton: ApiClient | None = None


def init_client():
    """Load a token and initialize the upstream client singleton at startup.

    The token is resolved from the environment variable, the file saved by
    ``--login``, or the desktop auth file (see ``find_and_load_token``).
    """
    global _client_singleton
    try:
        token_info = find_and_load_token()
        _client_singleton = ApiClient(DEFAULT_API_BASE, token_info, safe_mode=False)
        print("[+] CodeBuddy client initialized", file=sys.stderr)
    except Exception as e:
        print(f"[!] CodeBuddy client not initialized: {e}", file=sys.stderr)
        print("[!] Run `python server.py --login` or set CODEBUDDY_AUTH_TOKEN", file=sys.stderr)


def _get_client() -> ApiClient | None:
    """Return the shared client singleton (or None if no token was loaded)."""
    return _client_singleton


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize the client on startup; initialization failures do not block startup."""
    init_client()
    yield


app = FastAPI(
    title="WorkBuddy2API",
    description="OpenAI-compatible API wrapper for WorkBuddy / CodeBuddy (DeepSeek models)",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def verify_api_key(request: Request):
    """Validate the request API key."""
    if not API_KEY:
        return
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    if auth_header[7:] != API_KEY:
        raise HTTPException(status_code=403, detail="Invalid API key")


# -- OpenAI response helpers ---------------------------------------------------
def build_openai_chunk(
    chunk_id: str,
    model: str,
    content: str | None = None,
    reasoning_content: str | None = None,
    tool_calls: list | None = None,
    role: str | None = None,
    finish_reason: str | None = None,
    created: int | None = None,
) -> dict:
    """Build an OpenAI-compatible SSE chunk."""
    delta: dict = {}
    if role:
        delta["role"] = role
    if content:
        delta["content"] = content
    if reasoning_content:
        delta["reasoning_content"] = reasoning_content
    if tool_calls:
        delta["tool_calls"] = tool_calls
    return {
        "id": chunk_id,
        "object": "chat.completion.chunk",
        "created": created or int(time.time()),
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
    }


def build_openai_response(
    resp_id: str,
    model: str,
    content: str,
    reasoning_content: str = "",
    tool_calls: list | None = None,
    finish_reason: str = "stop",
    created: int | None = None,
) -> dict:
    """Build an OpenAI-compatible non-streaming response."""
    message: dict = {"role": "assistant", "content": content}
    if reasoning_content:
        message["reasoning_content"] = reasoning_content
    if tool_calls:
        message["tool_calls"] = tool_calls
    return {
        "id": resp_id,
        "object": "chat.completion",
        "created": created or int(time.time()),
        "model": model,
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


async def stream_chat_completion(client: ApiClient, body: dict, model: str) -> StreamingResponse:
    """Stream a chat request back to the client as SSE.

    The upstream API only supports streaming, so we always call it in streaming
    mode and re-emit the aggregated result as OpenAI-compatible chunks.
    """
    messages = body.get("messages", [])
    temperature = body.get("temperature", 0.7)
    max_tokens = body.get("max_tokens", MAX_TOKENS_DEFAULT)
    thinking_level = body.get("reasoning_effort") or body.get("thinking_level") or DEFAULT_THINKING_ENV
    tools = body.get("tools")
    tool_choice = body.get("tool_choice")
    chunk_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())

    async def generate():
        try:
            # OpenAI protocol requires an initial role chunk.
            yield f"data: {json.dumps(build_openai_chunk(chunk_id, model, role='assistant', created=created))}\n\n"

            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None,
                lambda: client.chat_completion(
                    messages=messages,
                    model=model,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    stream=True,
                    thinking_level=thinking_level,
                    tools=tools,
                    tool_choice=tool_choice,
                ),
            )

            if result is None:
                yield f"data: {json.dumps({'error': 'upstream API returned no content'})}\n\n"
                yield "data: [DONE]\n\n"
                return

            full_text = result.get("content", "") if isinstance(result, dict) else result
            reasoning_text = result.get("reasoning_content", "") if isinstance(result, dict) else ""
            tool_calls = result.get("tool_calls") if isinstance(result, dict) else None
            finish_reason = result.get("finish_reason", "stop") if isinstance(result, dict) else "stop"

            # Emit reasoning tokens first.
            if reasoning_text:
                chunk = build_openai_chunk(chunk_id, model, reasoning_content=reasoning_text,
                                           created=created)
                yield f"data: {json.dumps(chunk)}\n\n"
                await asyncio.sleep(0.02)

            if tool_calls:
                chunk = build_openai_chunk(chunk_id, model, tool_calls=tool_calls, created=created)
                yield f"data: {json.dumps(chunk)}\n\n"
                await asyncio.sleep(0.02)

            # Re-emit the full text in word-sized pieces to simulate streaming.
            for token in re.split(r"(\s+)", full_text):
                if token:
                    chunk = build_openai_chunk(chunk_id, model, content=token, created=created)
                    yield f"data: {json.dumps(chunk)}\n\n"
                    await asyncio.sleep(0.02)

            finish_chunk = build_openai_chunk(chunk_id, model, finish_reason=finish_reason,
                                              created=created)
            yield f"data: {json.dumps(finish_chunk)}\n\n"
            yield "data: [DONE]\n\n"

        except Exception as e:
            traceback.print_exc()
            yield f"data: {json.dumps({'error': str(e)})}\n\n"
            yield "data: [DONE]\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# -- Routes --------------------------------------------------------------------
@app.get("/health")
async def health():
    """Health check endpoint."""
    client = _get_client()
    return {
        "status": "ok" if client else "degraded",
        "codebuddy_configured": client is not None,
        "api_key_configured": bool(API_KEY),
    }


@app.get("/v1/models")
async def list_models(request: Request):
    """List the supported DeepSeek models (OpenAI-compatible)."""
    verify_api_key(request)

    data = []
    for m in sorted(KNOWN_CHAT_MODELS):
        data.append({
            "id": m,
            "object": "model",
            "created": 0,
            "owned_by": "workbuddy",
            "free": m in FREE_MODELS,
            "capabilities": {
                "chat": True,
                "reasoning": m in THINKING_CAPABLE_MODELS,
                "tools": True,
            },
        })
    return {"object": "list", "data": data}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    """OpenAI-compatible chat completions endpoint (streaming and non-streaming).

    Extra CodeBuddy-specific parameter:
      - reasoning_effort: "off"|"low"|"medium"|"high"|"max"
    """
    verify_api_key(request)

    client = _get_client()
    if client is None:
        raise HTTPException(
            status_code=503,
            detail="CodeBuddy token not configured. Run `python server.py --login` or set CODEBUDDY_AUTH_TOKEN.",
        )

    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body")

    messages = body.get("messages")
    if not messages or not isinstance(messages, list):
        raise HTTPException(status_code=400, detail="messages is required and must be an array")

    # Upstream requires the first message to be the system prompt; inject one
    # when the client did not provide it.
    first = messages[0] if isinstance(messages[0], dict) else {}
    if first.get("role") != "system":
        messages = [{"role": "system", "content": DEFAULT_SYSTEM_PROMPT}] + list(messages)
        body["messages"] = messages

    model = body.get("model", DEFAULT_MODEL)
    stream = body.get("stream", True)
    temperature = float(body.get("temperature", 0.7))
    max_tokens = int(body.get("max_tokens", MAX_TOKENS_DEFAULT))

    # Clamp values to sane ranges.
    if max_tokens > 32768:
        max_tokens = 32768
    temperature = max(0.0, min(2.0, temperature))
    body["max_tokens"] = max_tokens

    if stream:
        return await stream_chat_completion(client, body, model)

    # Non-streaming: still call upstream in streaming mode (the only mode it
    # supports), then return a single aggregated response.
    thinking_level = (
        body.get("reasoning_effort") or body.get("thinking_level") or DEFAULT_THINKING_ENV
    )
    try:
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(
            None,
            lambda: client.chat_completion(
                messages=messages,
                model=model,
                temperature=temperature,
                max_tokens=max_tokens,
                stream=True,
                thinking_level=thinking_level,
                tools=body.get("tools"),
                tool_choice=body.get("tool_choice"),
            ),
        )
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(status_code=502, detail=f"Upstream API error: {e}")

    if result is None:
        raise HTTPException(status_code=502, detail="Upstream API returned empty response")

    content = result.get("content", "") if isinstance(result, dict) else result
    reasoning = result.get("reasoning_content", "") if isinstance(result, dict) else ""
    tool_calls = result.get("tool_calls") if isinstance(result, dict) else None
    finish_reason = result.get("finish_reason", "stop") if isinstance(result, dict) else "stop"

    resp_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    return JSONResponse(build_openai_response(
        resp_id, model, content,
        reasoning_content=reasoning, tool_calls=tool_calls, finish_reason=finish_reason,
    ))


# -- Main ----------------------------------------------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="WorkBuddy2API - OpenAI-compatible server for WorkBuddy (DeepSeek).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python server.py --login            # sign in and save a token (works on Linux)\n"
            "  python server.py --setup-opencode   # register this server as an OpenCode provider\n"
            "  python server.py                    # start the API server\n"
        ),
    )
    parser.add_argument("--login", action="store_true",
                        help="Obtain a token via the WorkBuddy login flow, then exit")
    parser.add_argument("--platform", default="CLI",
                        help="Login platform (default: CLI)")
    parser.add_argument("--base", default=CODEBUDDY_WEB_BASE,
                        help=f"WorkBuddy web base URL (default: {CODEBUDDY_WEB_BASE})")
    parser.add_argument("--no-browser", action="store_true",
                        help="Do not try to open the login URL automatically")
    parser.add_argument("--login-timeout", type=int, default=300,
                        help="Seconds to wait for login to complete (default: 300)")
    parser.add_argument("--setup-opencode", action="store_true",
                        help="Register this server as a custom provider in the OpenCode config, then exit")
    parser.add_argument("--opencode-path", default=OPENCODE_DEFAULT_CONFIG,
                        help=f"OpenCode config file to update (default: {OPENCODE_DEFAULT_CONFIG})")
    parser.add_argument("--opencode-provider", default="workbuddy",
                        help="Provider id to use in the OpenCode config (default: workbuddy)")
    parser.add_argument("--opencode-base-url", default=None,
                        help=f"baseURL written to the provider (default: http://localhost:{PORT}/v1)")
    parser.add_argument("--opencode-api-key", default=None,
                        help="API key written to the provider (default: {env:WORKBUDDY_API_KEY})")
    parser.add_argument("--force", action="store_true",
                        help="Overwrite an existing provider entry instead of leaving it untouched")
    args = parser.parse_args()

    if args.login:
        sys.exit(do_login(args.base, args.platform,
                          open_browser=not args.no_browser, timeout=args.login_timeout))

    if args.setup_opencode:
        sys.exit(setup_opencode(
            path=args.opencode_path,
            provider_id=args.opencode_provider,
            base_url=args.opencode_base_url,
            api_key=args.opencode_api_key,
            force=args.force,
        ))

    import uvicorn
    print(f"[*] Starting WorkBuddy2API on port {PORT}", file=sys.stderr)
    print(f"[*] Default model: {DEFAULT_MODEL}", file=sys.stderr)
    print(f"[*] API key configured: {bool(API_KEY)}", file=sys.stderr)
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
