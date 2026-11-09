# AI Usage menu bar app

The app adds two menu bar items, one for Codex (vertical GPT label) and one for Claude (vertical CLA label). Each shows its label beside two stacked rows with the window label and remaining percentage. Percentages use a fixed, centered column. The nearest upcoming reset appears to the right with a small reset icon beside two stacked numbers: the local 24-hour hour above the minutes (for example, `23` above `30` means 23:30). This reset group is omitted when no future reset is available. Hover for the next reset's window, full date, and a full usage summary, or open its menu for reset dates, available earned reset credits and their known expiry times, **Refresh now**, and **Quit AI Usage**. Reset credits are Codex-only. It refreshes every five minutes while running.

Allow notifications when macOS asks to receive one alert per available reset credit when it is within 24 hours of expiring. Keep the app running for expiry checks. You can manage alerts in **System Settings > Notifications > AI Usage**.

## Open on this Mac

```sh
open 'dist/AI Usage.app'
```

To start it automatically after logging in, add **AI Usage.app** in **System Settings > General > Login Items & Extensions > Open at Login**. Keep the app at this path after adding it.

## Rebuild after changing the source

```sh
zsh build_app.sh
```

The app uses the bundled `codex_usage.py` script and the Codex CLI included with the ChatGPT desktop app, and the bundled `claude_usage.py` script with Claude Code's saved sign-in (the `Claude Code-credentials` Keychain item, or `~/.claude/.credentials.json`) to read the 5-hour and 7-day Claude plan limits. No API key is needed. If the Claude item shows a sign-in expired error, open Claude Code once so it refreshes its token. The standalone terminal checks remain available with `python3 codex_usage.py` and `python3 claude_usage.py`.

## Share with another Mac

The prebuilt app has no Apple Developer ID signature or notarization, so a downloaded copy is blocked by Gatekeeper. Share the source archive instead. On the recipient's Mac, after installing Xcode Command Line Tools if needed, extract the archive and run:

```sh
cd 'AI Usage Source'
zsh build_app.sh
open 'dist/AI Usage.app'
```

They also need the ChatGPT/Codex desktop app signed in, Claude Code signed in with a Claude subscription, and a working `/usr/bin/python3`. The build uses their Mac's Swift compiler and architecture. For ordinary drag-and-drop app distribution, sign and notarize the app with an Apple Developer ID.
