#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import sys
import time
from pathlib import Path

CLINE_HOME = Path(os.environ.get("CLINE_HOME", Path.home() / ".cline"))
DATA = CLINE_HOME / "data"
SETTINGS = DATA / "settings"
CACHE = DATA / "cache"
LOGS = DATA / "logs"
SESSIONS = DATA / "sessions"

PROVIDERS = SETTINGS / "providers.json"
FEATURE_FLAGS = CACHE / "feature-flags.json"
CLI_NOTICES = SETTINGS / "cli-notices.json"
AUTH_KEYS = ("auth", "accessToken", "refreshToken", "expiresAt", "accountId", "tokenSource", "metadata")


def load_json(path, default):
    if not path.exists():
        return default
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except (json.JSONDecodeError, OSError):
        return default


def atomic_write(path, payload, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, mode)
    tmp.replace(path)


def backup(path):
    if not path.exists():
        return None
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = path.with_suffix(path.suffix + f".bak-{stamp}")
    shutil.copy2(path, dest)
    return dest


def strip_auth(settings):
    for key in AUTH_KEYS:
        settings.pop(key, None)
    return settings


def clean_providers(keep_model=True):
    data = load_json(PROVIDERS, {"version": 1, "lastUsedProvider": "cline", "modes": {}, "providers": {}})
    backup(PROVIDERS)
    providers = data.get("providers", {})
    for name, entry in providers.items():
        if not isinstance(entry, dict):
            continue
        entry.pop("tokenSource", None)
        entry.pop("updatedAt", None)
        settings = entry.get("settings")
        if isinstance(settings, dict):
            settings = strip_auth(settings)
            if not keep_model:
                settings.pop("model", None)
            entry["settings"] = settings
    data["providers"] = providers
    if not keep_model:
        data["lastUsedProvider"] = None
        data["modes"] = {}
    atomic_write(PROVIDERS, data)
    return data


def clean_feature_flags():
    data = load_json(FEATURE_FLAGS, None)
    if data is not None:
        backup(FEATURE_FLAGS)
    payload = {"version": 2, "updatedAt": int(time.time() * 1000), "flagsPayload": {"featureFlags": {}, "featureFlagPayloads": {}}}
    atomic_write(FEATURE_FLAGS, payload)
    return payload


def clean_notices():
    if CLI_NOTICES.exists():
        backup(CLI_NOTICES)
    atomic_write(CLI_NOTICES, {"shown": {}})


def purge_sessions():
    removed = 0
    if SESSIONS.exists():
        for child in SESSIONS.iterdir():
            if child.is_file():
                child.unlink()
                removed += 1
    return removed


def purge_logs():
    removed = 0
    if LOGS.exists():
        for child in LOGS.iterdir():
            if child.is_file() and child.suffix == ".log":
                child.write_text("", encoding="utf-8")
                removed += 1
    return removed


def purge_cache():
    removed = 0
    for name in ("sessions", "cache"):
        target = DATA / name
        if target.exists():
            for child in target.iterdir():
                if child.is_file() and child.name != "feature-flags.json":
                    child.unlink()
                    removed += 1
    return removed


def show_status():
    data = load_json(PROVIDERS, {})
    providers = data.get("providers", {})
    for name, entry in providers.items():
        settings = entry.get("settings", {}) if isinstance(entry, dict) else {}
        auth = settings.get("auth", {})
        token = auth.get("accessToken")
        print(f"provider={name} tokenSource={entry.get('tokenSource')} account={auth.get('accountId')} token={'set' if token else 'empty'}")
    flags = load_json(FEATURE_FLAGS, {})
    print(f"featureFlags={flags.get('flagsPayload', {}).get('featureFlags', {})}")


def main():
    global CLINE_HOME, DATA, SETTINGS, CACHE, LOGS, SESSIONS, PROVIDERS, FEATURE_FLAGS, CLI_NOTICES

    parser = argparse.ArgumentParser(description="Rotate/empty the stored Cline account session")
    parser.add_argument("--all", action="store_true", help="also drop model selection and lastUsedProvider")
    parser.add_argument("--sessions", action="store_true", help="purge stored session transcripts")
    parser.add_argument("--logs", action="store_true", help="truncate cline logs")
    parser.add_argument("--cache", action="store_true", help="purge cache artifacts")
    parser.add_argument("--status", action="store_true", help="print current auth state and exit")
    parser.add_argument("--home", default=str(CLINE_HOME), help="override CLINE_HOME")
    args = parser.parse_args()

    CLINE_HOME = Path(args.home)
    DATA = CLINE_HOME / "data"
    SETTINGS = DATA / "settings"
    CACHE = DATA / "cache"
    LOGS = DATA / "logs"
    SESSIONS = DATA / "sessions"
    PROVIDERS = SETTINGS / "providers.json"
    FEATURE_FLAGS = CACHE / "feature-flags.json"
    CLI_NOTICES = SETTINGS / "cli-notices.json"

    if args.status:
        show_status()
        return 0

    if not PROVIDERS.exists():
        print(f"no providers.json at {PROVIDERS}", file=sys.stderr)
        return 1

    clean_providers(keep_model=not args.all)
    clean_feature_flags()
    clean_notices()
    print(f"auth cleared: {PROVIDERS}")

    if args.sessions:
        print(f"sessions purged: {purge_sessions()}")
    if args.logs:
        print(f"logs truncated: {purge_logs()}")
    if args.cache:
        print(f"cache purged: {purge_cache()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())