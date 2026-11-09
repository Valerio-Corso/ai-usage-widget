#!/usr/bin/env python3
"""Show the current Claude plan usage through Claude Code's sign-in."""

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
WINDOWS = {"five_hour": 300, "seven_day": 10_080}


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
        raise RuntimeError("Claude Code sign-in not found. Sign in to Claude Code first.")
    token = (json.loads(stored).get("claudeAiOauth") or {}).get("accessToken")
    if not token:
        raise RuntimeError("Claude Code is not signed in with a Claude subscription.")
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


def main():
    parser = argparse.ArgumentParser(description="Show current Claude usage limits")
    parser.add_argument("--json", action="store_true", help="Print the quota in the menu app's JSON shape")
    args = parser.parse_args()
    usage = read_usage()
    primary, secondary = (window(usage.get(key), minutes) for key, minutes in WINDOWS.items())
    if not primary and not secondary:
        raise RuntimeError("No Claude quota returned. Check that Claude Code is signed in with a subscription.")
    if args.json:
        print(json.dumps({"limits": {"claude": {"primary": primary, "secondary": secondary}}}))
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
