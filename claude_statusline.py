#!/usr/bin/python3
"""Claude Code status line: show plan usage and share it with the AI Usage menu bar app.

Claude Code passes its latest rate limits on stdin, so the app can read them without
calling the usage endpoint, which rate-limits busy accounts.
"""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

FEED = Path.home() / "Library" / "Caches" / "AI Usage" / "claude_statusline.json"
LABELS = {"five_hour": "5h", "seven_day": "7d"}


def main():
    try:
        limits = json.load(sys.stdin).get("rate_limits") or {}
    except (ValueError, AttributeError):
        return
    windows = {key: limits[key] for key in LABELS
               if isinstance(limits.get(key), dict) and limits[key].get("used_percentage") is not None}
    if not windows:
        return
    FEED.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=FEED.parent, delete=False) as file:
        json.dump({"updatedAt": time.time(), **windows}, file)
    os.replace(file.name, FEED)
    print(" · ".join(f"{LABELS[key]} {max(0, 100 - data['used_percentage']):.0f}% left"
                     for key, data in windows.items()))


if __name__ == "__main__":
    main()
