#!/usr/bin/env python3
"""Show the current Claude plan usage through Claude Code's sign-in."""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
WINDOWS = {"five_hour": 300, "seven_day": 10_080}
CACHE = Path.home() / "Library" / "Caches" / "AI Usage"
FEED = CACHE / "claude_statusline.json"  # written by claude_statusline.py
STATE = CACHE / "claude_usage_state.json"  # last result and any rate-limit lockout
FEED_MAX_AGE = 10 * 60


class RateLimited(RuntimeError):
    def __init__(self, until):
        super().__init__(f"Usage checks are rate limited until {datetime.fromtimestamp(until):%H:%M}.")
        self.until = until


def access_token():
    try:
        stored = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except subprocess.TimeoutExpired:
        stored = ""
    if not stored:
        file = Path.home() / ".claude" / ".credentials.json"
        stored = file.read_text() if file.is_file() else ""
    if not stored:
        raise RuntimeError("Claude Code sign-in not found. Run `claude /login` in Terminal.")
    token = (json.loads(stored).get("claudeAiOauth") or {}).get("accessToken")
    if not token:
        raise RuntimeError("No Claude account sign-in saved for Claude Code. Run `claude /login` in Terminal.")
    return token


def read_usage():
    request = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {access_token()}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "local-usage-check/1.0",
    })
    try:
        with urllib.request.urlopen(request, timeout=20) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise RuntimeError("Claude Code sign-in expired. Open Claude Code to refresh it.") from None
        if error.code == 429:
            retry = error.headers.get("Retry-After", "")
            raise RateLimited(time.time() + (int(retry) if retry.isdigit() else 600)) from None
        raise RuntimeError(f"Claude usage request failed (HTTP {error.code}).") from None
    except urllib.error.URLError as error:
        raise RuntimeError(f"Claude usage request failed: {error.reason}") from None


def window(data, duration):
    if not data or data.get("utilization") is None:
        return None
    reset = data.get("resets_at")
    return {
        "usedPercent": float(data["utilization"]),
        "windowDurationMins": duration,
        "resetsAt": datetime.fromisoformat(re.sub(r"\.\d+", "", reset).replace("Z", "+00:00")).timestamp() if reset else None,
    }


def from_feed(now):
    try:
        feed = json.loads(FEED.read_text())
        windows = [{
            "usedPercent": float(feed[key]["used_percentage"]),
            "windowDurationMins": minutes,
            "resetsAt": feed[key].get("resets_at"),
        } if key in feed else None for key, minutes in WINDOWS.items()]
        updated = float(feed["updatedAt"])
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None
    # Claude Code only updates the feed while a session is active, and a window reset outdates it.
    if now - updated > FEED_MAX_AGE or any(w and w["resetsAt"] and w["resetsAt"] <= now for w in windows):
        return None
    return windows, updated


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state):
    CACHE.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=CACHE, delete=False) as file:
        json.dump(state, file)
    os.replace(file.name, STATE)


def current_windows(state):
    now = time.time()
    fed = from_feed(now)
    if fed:
        return fed
    if state.get("blockedUntil", 0) > now:
        raise RateLimited(state["blockedUntil"])
    try:
        usage = read_usage()
    except RateLimited as limited:
        state["blockedUntil"] = limited.until
        save_state(state)
        raise
    return [window(usage.get(key), minutes) for key, minutes in WINDOWS.items()], now


def main():
    parser = argparse.ArgumentParser(description="Show current Claude usage limits")
    parser.add_argument("--json", action="store_true", help="Print the quota in the menu app's JSON shape")
    args = parser.parse_args()
    state = load_state()
    try:
        (primary, secondary), fetched = current_windows(state)
        if not primary and not secondary:
            raise RuntimeError("No Claude quota returned. Check that Claude Code is signed in with a subscription.")
        result = {"limits": {"claude": {"primary": primary, "secondary": secondary}}, "fetchedAt": fetched}
        state["last"] = result
        save_state(state)
    except RuntimeError as error:
        # The app shows the last values, dimmed, with this message.
        if not (args.json and state.get("last")):
            raise
        result = {**state["last"], "error": str(error)}
    if args.json:
        print(json.dumps(result))
        return
    for label, data in (("Session (5h)", primary), ("Weekly (7d)", secondary)):
        if not data:
            continue
        reset = data["resetsAt"]
        reset_text = datetime.fromtimestamp(reset).astimezone().strftime("%Y-%m-%d %H:%M %Z") if reset else "unknown"
        print(f"{label}: {max(0, 100 - data['usedPercent']):g}% remaining; resets {reset_text}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, TypeError) as error:
        print(f"claude_usage: {error}", file=sys.stderr)
        sys.exit(1)
