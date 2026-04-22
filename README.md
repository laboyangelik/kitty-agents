# kitty agents

<video src="kitty-agents-intro.mp4" autoplay loop muted playsinline></video>

A tiny AI cat that lives on your macOS dock. Built on top of [lil agents](https://github.com/ryanstephen/lil-agents) by [@ryanstephen](https://github.com/ryanstephen) — go give that repo a star. Uses the cat animation from [Cat Pomodoro](https://rive.app/marketplace/27136-51126-cat-pomodoro/) on Rive.

**kitty agents** sits above your dock, vibing. Click to open an AI terminal and chat. It thinks, idles, and silently judges you.

Supports **Claude Code**, **OpenAI Codex**, **GitHub Copilot**, **Google Gemini**, and **OpenCode** — switch between them from the menu bar.

---

## installing

**[download kitty agents here](https://github.com/laboyangelik/kitty-agents/releases/latest/download/kitty-agents-latest.zip)**

1. Download the zip above and unzip it
2. Drag **kitty agents.app** to your Applications folder
3. Double-click to open — if macOS warns you about an unverified developer, right-click the app and choose **Open** instead
4. The cat appears above your dock and walks around

The app updates itself automatically in the background via Sparkle — you'll get a prompt whenever a new version is ready.

## requirements

- macOS Sonoma 14.0 or later
- Apple Silicon or Intel Mac

At least one AI provider — Claude, Codex, Gemini, Copilot, OpenCode, or OpenClaw. The app will detect what you have installed automatically, and can walk you through installing Claude, Codex, or Gemini from inside the chat.

---

## features

- Rive-animated cat that lives above your dock
- Click to open an AI chat terminal popover
- **Built-in install wizard** — for Claude, Codex, and Gemini, click the install button and the app walks you through setup without ever opening a terminal
- Animated loading indicator while installs are running so you always know it's working
- 7 cat colors: Gray, Ungu, Blue, Calico, Black, White, Orange
- Switch AI providers per-character from the menu bar
- Thinking bubbles and animated status while your agent is working
- Model picker — switch between opus/sonnet/haiku (Claude) or flash/pro (Gemini) without leaving the chat
- MCP server support for Claude
- Sound effects on completion
- Launch at login
- Resize the cat: Large, Medium, or Small
- Pin to a specific display on multi-monitor setups
- Triple-tap the kitty to quit
- Auto-updates via Sparkle

---

## chat commands

Type any of these in the chat input:

| command | what it does |
|---|---|
| `/clear` | wipe the conversation and start a new session |
| `/copy` | copy the last response to your clipboard |
| `/model` | open an interactive model picker (↑↓ to select, enter to confirm) |
| `/model opus` | switch directly to a specific model alias |
| `/mcp` | list your configured MCP servers |

---

## provider setup

For **Claude**, **Codex**, and **Gemini** — you don't need to set anything up manually. Click the **install** button in the app (next to the hammer icon in the chat header) and kitty agents will walk you through creating an account and getting everything configured right in the chat window.

For providers without a built-in flow, install manually:

**GitHub Copilot**
```
brew install copilot-cli
```
Then run `copilot auth` to authenticate with your GitHub account.

**OpenCode**
```
curl -fsSL https://opencode.ai/install | bash
```

**OpenClaw** — a self-hosted AI gateway. Install and run it, then paste your auth token in the app settings.

Once a CLI is installed and authenticated, it shows up automatically in menu bar → Provider. Unavailable providers are grayed out.

---

## menu bar

![menu bar](menubar-preview.gif)

Click the cat icon in the menu bar to access:

- **Hide / Show Cat** — toggle kitty on and off
- **Sounds** — turn sound effects on or off
- **Provider** — switch AI providers (only installed ones are enabled)
- **Color** — pick kitty's color
- **Size** — Large, Medium, or Small
- **Display** — pin kitty to a specific monitor
- **Launch at Login** — start automatically on login
- **Check for Updates** — manually check for a new version
- **Quit** — close the app

---

## building from source

Clone the repo, open `lil-agents.xcodeproj` in Xcode, and hit Run.

---

## privacy

kitty agents runs entirely on your Mac and sends nothing on its own.

- **Your data stays local.** The app draws animations and calculates your dock position. No personal data is collected or transmitted by the app.
- **AI providers.** Conversations go through whichever CLI you pick, running locally on your machine. kitty agents does not intercept or store your chat content. What gets sent to the AI provider is governed by their own privacy policy.
- **No accounts.** No login, no analytics, no user database.
- **Updates.** Sparkle checks for updates and sends your app version and macOS version. Nothing else.

---

## license

MIT — see [LICENSE](LICENSE) for details.
