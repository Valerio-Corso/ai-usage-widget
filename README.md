# AI Usage

A macOS menu bar app that shows how much of your Claude Code and Codex (ChatGPT) plan limits you have left: the 5-hour and weekly windows, with a countdown to each reset.

| Bars layout | Numbers layout |
| --- | --- |
| ![Bars layout: a bar per window for GPT and CLA, with 60% and 29% remaining](docs/bars-layout.png) | ![Numbers layout: 5h and 7d rows for GPT and CLA with remaining percentage and reset countdown](docs/numbers-layout.png) |

## Install

1. Download `AI Usage.zip` from the [latest release](https://github.com/Valerio-Corso/ai-usage-widget/releases/latest).
2. Unzip it, move **AI Usage.app** to Applications, and open it.

Requirements:

- macOS 11 or later (Apple Silicon or Intel)
- For Claude: Claude Code signed in with a Claude subscription (`claude /login`)
- For Codex: the ChatGPT desktop app (with Codex) signed in
- `/usr/bin/python3` (macOS offers to install it on first use)

To start it at login, add it in **System Settings > General > Login Items**.

## Usage

- **Bars layout** shows one bar per window and the remaining percentage of the tightest one. **Numbers layout** shows each window's remaining percentage and time to reset.
- Values turn orange at 20% left and red at 10%.
- Hover for a summary, or click for reset dates, **Settings**, and **Refresh now**. It refreshes every five minutes.
- In **Settings**, choose which services to track and the layout, and turn alerts for expiring Codex reset credits on or off.
- A dimmed value with `⚠` means the last refresh failed. The menu says why.

### Avoid Claude rate limits

Claude's usage endpoint rate-limits busy accounts. To avoid that, let Claude Code pass its limits to the app by adding this to `~/.claude/settings.json`:

```json
"statusLine": {"type": "command", "command": "/usr/bin/python3 '/Applications/AI Usage.app/Contents/Resources/claude_statusline.py'"}
```

Your terminal status line then also shows them, for example `5h 66% left · 7d 29% left`.

## Privacy

- **Claude**: reads Claude Code's saved sign-in (Keychain item `Claude Code-credentials` or `~/.claude/.credentials.json`) and calls `api.anthropic.com/api/oauth/usage`.
- **Codex**: asks the local Codex CLI that ships with the ChatGPT app.
- It makes no other network requests and collects no analytics. Cached values live in `~/Library/Caches/AI Usage`.

## Troubleshooting

- **Claude sign-in error**: run `claude /login`. If it says the sign-in expired, run `claude` once to refresh it.
- **Check from the terminal**: `python3 claude_usage.py` or `python3 codex_usage.py`.

## Build from source

```sh
zsh build_app.sh
open 'dist/AI Usage.app'
```

This builds a universal app. It is signed with your **Developer ID Application** certificate if you have one, and otherwise signed ad hoc, which only runs on your Mac.

To make a release, save notarization credentials once:

```sh
xcrun notarytool store-credentials AI-Usage-Notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Then run `zsh build_app.sh --notarize`. It notarizes and staples the app and writes `dist/AI Usage.zip`. Set `DEVELOPER_ID` or `NOTARY_PROFILE` to use a different certificate or profile.

## License

[MIT](LICENSE). Not affiliated with Anthropic or OpenAI.
