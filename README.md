# TokenBar — macOS AI Usage Monitor

A lightweight, local macOS menu bar app for tracking real-time rate limits, usage quotas, and token consumption across **Claude Code**, **OpenAI Codex**, and **Google Antigravity** — no cloud sync, no telemetry, 100% on-device.

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2013%2B-blue">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9%2B-orange">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
</p>

<p align="center">
  <img src="assets/overview.png" alt="TokenBar Overview" width="420" style="border-radius: 8px;"/>
</p>

---

## Features

- **Claude Code Limits**: Reads live session percentages, weekly quotas, and reset countdowns by querying the local `claude` CLI (`--safe-mode -p /usage`), combined with the last 30 days of local session history from `~/.claude/projects/`.
- **OpenAI Codex Limits**: Queries live account status and rate limit reset credits via `codex app-server --stdio` JSON-RPC (with fallback to `~/.codex/sessions/*.jsonl`), extracts subscription tier from `~/.codex/auth.json`, and reconstructs daily and per-model usage from local timestamped session events.
- **Google Antigravity Limits**: Reads model-family 5-hour and weekly quotas from the local service of a running Antigravity desktop app or IDE, and parses local conversation databases under `~/.gemini` for token history.
- **14-Day Activity Visualization**: Stacked daily token chart comparing Claude Code, Codex, and Antigravity.
- **Model Breakdown**: Provider-qualified token totals for every locally observed model.
- **Auto & Manual Refresh**: Configurable auto-refresh intervals (1, 5, or 15 minutes) or instant manual refresh.
- **100% Local & Native**: Built with SwiftUI (`MenuBarExtra`) for macOS 13+. Operates entirely on your local machine with zero remote tracking, telemetry, or external network dependencies.

---

## Showcase

| Overview | Model Breakdown |
| :---: | :---: |
| ![Overview](assets/overview.png) | ![Models](assets/models.png) |

| Claude Detail | Codex Detail |
| :---: | :---: |
| ![Claude](assets/claude.png) | ![Codex](assets/codex.png) |

<p align="center">
  <img src="assets/settings.png" alt="Settings & Customization" width="480" style="border-radius: 8px;"/>
</p>

---

The menu bar's ⚡ value is today's recorded local tokens across providers, excluding cache reads. `…` means the first refresh is pending, `—` means unavailable, and a trailing `+` means the total is partial. Subscription percentages are independent of these local totals.

## How It Works

TokenBar inspects local CLI environment state and local application stores:

1. **Claude Code Integration (`ClaudeDataReader.swift`)**
   - **Live Status**: Spawns `claude --safe-mode -p /usage --output-format json` in a background subprocess (15s timeout) to extract active 5-hour session and weekly rate limit percentages.
   - **Scope**: Subscription limits cover the same account across devices, including SSH hosts; no remote-host configuration is needed. Missing limits are shown as unavailable, never inferred as zero. Refresh uses a Claude Code version supporting `--safe-mode` to disable user customizations and hooks while preserving login.
   - **Local history**: Tokens, model totals, messages, and charts reflect this Mac only. Claude history is rebuilt for the last 30 days directly from local transcripts, without relying on `stats-cache.json`. The activity chart displays the latest 14 days.
   - **History**: Reads JSONL files under `~/.claude/projects/` in bounded chunks. Unchanged files reuse in-memory parsed metadata; changed files are reread and removed files are dropped on the next refresh. Duplicate message IDs and streaming usage snapshots are consolidated across files. Tokens include input, output, and cache creation; cache reads are displayed separately and excluded from totals. Session counts exclude subagent sidechains. No conversations or credentials are copied, and the original files are never modified. Deleted transcripts cannot be recovered from the old aggregate cache.

2. **OpenAI Codex Integration (`CodexDataReader.swift`)**
   - **Live Status**: Runs `codex app-server --stdio` over JSON-RPC to invoke `account/rateLimits/read` for active window limits and reset credits. If the app-server process is inactive, falls back to reading recent local `~/.codex/sessions/*.jsonl` events.
   - **Account & Config**: Decodes user email and plan tier (`chatgpt_plan_type`) from JWT tokens in `~/.codex/auth.json`, and reads configured active model from `~/.codex/config.toml`.
   - **History**: Reads `~/.codex/sessions/` and `~/.codex/archived_sessions/` incrementally. Cumulative token snapshots are converted to increments and assigned to each event's local date and active model, so sessions spanning midnight count on both days. Repeated snapshots and copied session files are deduplicated. Totals cover the last 30 days; the seven-day window uses event dates too. Cache reads are excluded, consistently with Claude. Missing baselines or unreadable records mark the history as partial instead of assigning lifetime usage to today.

3. **Google Antigravity Integration (`AntigravityDataReader.swift`)**
   - **Live Status**: Connects to the authenticated localhost service of an already-running Antigravity app or IDE. Refresh never launches `agy`, which can open a browser login and steal focus when authentication is needed. It does not copy or persist local credentials.
   - **History**: Opens Antigravity and Antigravity CLI conversation databases under `~/.gemini` in read-only mode, deduplicates responses, and recovers modern per-turn timestamps from the `steps` table.
   - **Availability**: Historical activity remains available while Antigravity is closed. Live quota refresh requires a running, signed-in desktop app/IDE.

---

## Building & Installation

### Requirements
- macOS 13.0 (Ventura) or later
- Swift 5.9+ / Xcode Command Line Tools
- `claude`, `codex`, and/or Antigravity installed locally

### Build from Source

```bash
# Clone the repository
git clone https://github.com/meet30997/ai_usage_widget.git
cd ai_usage_widget

# Run tests
swift test

# Build the release app bundle
./build_app.sh

# Open the app bundle
open "build/AI Usage Tracker.app"
```

To install system-wide, move `build/AI Usage Tracker.app` into your `/Applications` folder.

### Automated Versioning and Releases

TokenBar follows [Semantic Versioning 2.0.0](https://semver.org/). The public app version lives in `VERSION` using the stable `MAJOR.MINOR.PATCH` format, while `BUILD_NUMBER` contains Apple's monotonically increasing internal build number. The Settings screen reads both values from the generated app bundle.

Pushes to `main` run the Semantic Release workflow. It inspects Conventional Commits since the latest `vMAJOR.MINOR.PATCH` tag, calculates the next version, increments the build, builds and signs the app, commits the version files, creates the tag, and publishes a zipped app bundle as a GitHub release.

```bash
fix: correct quota status      # patch: 1.4.2 -> 1.4.3
feat: add another provider     # minor: 1.4.2 -> 1.5.0
feat!: change history format   # major: 1.4.2 -> 2.0.0
```

`docs:`, `test:`, `ci:`, `build:`, `chore:`, and `style:` commits do not create a release. Legacy non-conventional commit messages default to a patch release so existing changes are not silently omitted. Preview the next automatic version locally without modifying files:

```bash
./scripts/semantic_release.sh --dry-run
```

For an exceptional manual version override, `./scripts/bump_version.sh major|minor|patch` remains available. `build_app.sh` always validates the version files and writes them to `CFBundleShortVersionString` and `CFBundleVersion`.

---

## License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for details.
