# AI Usage menu bar app

The app adds one menu bar item that shows Codex (vertical GPT label) and Claude (vertical CLA label) side by side, in one of two layouts chosen under **Settings**. **Bars layout** (the default) shows a bar per usage window, shorter window on top, filled by the share remaining, beside the remaining percentage of the tightest window. **Numbers layout** shows two stacked rows with the window label, remaining percentage in a fixed column, and a countdown to that window's reset (for example, `4h59`, `25h`, or `3d`). A window with 20% or less remaining turns orange, and red at 10% or less; in the bars layout the countdown to its reset then appears beside the percentage. Hover for the next reset's window, full date, and a full usage summary, or open its menu for each service's reset dates, available earned reset credits and their known expiry times (Codex only), **Settings**, **Refresh now**, and **Quit AI Usage**. A service that is still loading shows `…`. One that failed keeps its last values dimmed with a small `⚠` until one of those windows resets, or shows `⚠` alone when there are none; its menu section explains why and when the values were last updated. It refreshes every five minutes while running.

Use **Settings** to choose which services to track (**Track Codex**, **Track Claude**) and the menu bar layout (**Bars layout**, **Numbers layout**). Untracked services are hidden and not checked. Allow notifications when macOS asks to receive one alert per available reset credit when it is within 24 hours of expiring; turn these off with **Settings > Reset credit expiry alerts**. **Settings > Send test notification** sends a sample alert right away, or offers to open System Settings if notifications are off. Keep the app running for expiry checks. You can manage alerts in **System Settings > Notifications > AI Usage**.

## Open on this Mac

```sh
open 'dist/AI Usage.app'
```

To start it automatically after logging in, add **AI Usage.app** in **System Settings > General > Login Items & Extensions > Open at Login**. Keep the app at this path after adding it.

## Rebuild after changing the source

```sh
zsh build_app.sh
```

The app uses the bundled `codex_usage.py` script and the Codex CLI included with the ChatGPT desktop app, and the bundled `claude_usage.py` script with Claude Code's saved sign-in (the `Claude Code-credentials` Keychain item, or `~/.claude/.credentials.json`) to read the 5-hour and 7-day Claude plan limits. No API key is needed. If Claude shows a sign-in error, run `claude /login` in Terminal; if it says the sign-in expired, run `claude` once so it refreshes its token. The standalone terminal checks remain available with `python3 codex_usage.py` and `python3 claude_usage.py`.

Claude's usage endpoint rate-limits busy accounts, since Claude Code sessions call it too. To avoid it, set the bundled `claude_statusline.py` as Claude Code's status line: active Claude Code sessions then hand their latest limits to the app, and the terminal shows them too (for example, `5h 66% left · 7d 29% left`). Add this to `~/.claude/settings.json`, with the path to where you keep the app:

```json
"statusLine": {"type": "command", "command": "/usr/bin/python3 '/Applications/AI Usage.app/Contents/Resources/claude_statusline.py'"}
```

The app uses those limits while they are under 10 minutes old and no window has reset since. Otherwise it calls the endpoint, and when that is rate-limited it waits until the time the endpoint gives before calling again. Meanwhile it keeps showing the last values, dimmed, with the reason and time in the menu. Both files live in `~/Library/Caches/AI Usage`.

## Share with another Mac

`build_app.sh` builds one universal app (Apple Silicon and Intel, macOS 11 or later). It signs with your **Developer ID Application** certificate when one is installed, and otherwise signs it ad hoc, which only runs on the Mac that built it.

One-time setup:

1. Create the certificate in **Xcode > Settings > Accounts**: select your team, click **Manage Certificates…**, then **+ > Developer ID Application**. Only the team's Account Holder can create it.
2. Create an app-specific password at [account.apple.com](https://account.apple.com) under **Sign-In and Security > App-Specific Passwords**, then save notarization credentials in your Keychain (it asks for that password):

```sh
xcrun notarytool store-credentials AI-Usage-Notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Then build, notarize, and package:

```sh
zsh build_app.sh --notarize
```

This uploads the app to Apple, waits for approval (usually a few minutes), staples the ticket, and writes `dist/AI Usage.zip`. Send that zip; the recipient unzips it, moves **AI Usage.app** to Applications, and opens it normally. Set `DEVELOPER_ID` to pick a specific certificate, or `NOTARY_PROFILE` to use a different saved profile.

The recipient also needs the ChatGPT/Codex desktop app signed in to track Codex, Claude Code signed in with a Claude subscription (`claude /login`) to track Claude, and a working `/usr/bin/python3` (macOS offers to install the Command Line Tools on first use).
