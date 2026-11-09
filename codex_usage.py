#!/usr/bin/env python3
"""Show the current ChatGPT Codex quota through the local Codex app-server."""

import json
import argparse
import select
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


def codex_executable():
    found = shutil.which("codex")
    if found:
        return found
    bundled = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    if bundled.is_file():
        return str(bundled)
    raise RuntimeError("Codex CLI not found. Install/open the Codex desktop app or add codex to PATH.")


def send(process, message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def response(process, request_id, deadline):
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        readable, _, _ = select.select([process.stdout], [], [], remaining)
        if not readable:
            break
        line = process.stdout.readline()
        if not line:
            raise RuntimeError("Codex app-server closed before responding.")
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get("id") == request_id:
            if "error" in message:
                raise RuntimeError(message["error"].get("message", "Codex app-server error"))
            return message["result"]
    raise RuntimeError("Timed out waiting for Codex app-server.")


def show_window(label, window):
    if not window or window.get("usedPercent") is None:
        return
    remaining = max(0, min(100, 100 - window["usedPercent"]))
    duration = window.get("windowDurationMins")
    period = f"{duration // 60}h" if duration and duration % 60 == 0 else f"{duration}m"
    reset = window.get("resetsAt")
    reset_text = datetime.fromtimestamp(reset).astimezone().strftime("%Y-%m-%d %H:%M %Z") if reset else "unknown"
    print(f"{label} ({period}): {remaining:g}% remaining; resets {reset_text}")


def main():
    parser = argparse.ArgumentParser(description="Show current Codex usage limits")
    parser.add_argument("--json", action="store_true", help="Print the quota response as JSON")
    args = parser.parse_args()
    process = subprocess.Popen(
        [codex_executable(), "app-server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    try:
        deadline = time.monotonic() + 20
        send(process, {"id": 1, "method": "initialize", "params": {
            "clientInfo": {"name": "local_usage_check", "title": "Local Usage Check", "version": "1.0"}
        }})
        response(process, 1, deadline)
        send(process, {"method": "initialized", "params": {}})
        send(process, {"id": 2, "method": "account/rateLimits/read", "params": {}})
        result = response(process, 2, deadline)
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    limits = result.get("rateLimitsByLimitId") or {}
    if not limits and result.get("rateLimits"):
        limits = {"codex": result["rateLimits"]}
    if not limits:
        raise RuntimeError("No Codex quota returned. Check that Codex is signed in with ChatGPT.")
    if args.json:
        reset_credits = result.get("rateLimitResetCredits") or {}
        reset_credit_expiries = [
            {"id": credit["id"], "expiresAt": credit["expiresAt"]}
            for credit in (reset_credits.get("credits") or [])
            if credit.get("status") == "available" and credit.get("id") and credit.get("expiresAt") is not None
        ]
        print(json.dumps({
            "limits": limits,
            "resetCreditsAvailable": reset_credits.get("availableCount"),
            "resetCreditExpiries": reset_credit_expiries,
        }))
        return
    for limit_id, limit in limits.items():
        print(limit.get("limitName") or limit_id)
        show_window("  Short window", limit.get("primary"))
        show_window("  Long window", limit.get("secondary"))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, TypeError) as error:
        print(f"codex_usage: {error}", file=sys.stderr)
        sys.exit(1)
