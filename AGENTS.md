# Repository Guidelines

## Project Structure & Module Organization

TokenBar is a native SwiftUI menu bar app for macOS 13+, built with Swift Package Manager and Swift 5.9+.

- `Sources/AIUsageWidget/AIUsageWidgetApp.swift`: application entry point.
- `Sources/AIUsageWidget/Models/`: provider usage types and combined metrics.
- `Sources/AIUsageWidget/Services/`: Claude, Codex, and Antigravity readers, usage coordination, and brand assets.
- `Sources/AIUsageWidget/Views/`: popovers, provider details, charts, settings, and shared design components.
- `Tests/AIUsageWidgetTests/`: XCTest regression tests.
- `assets/`: PNG brand images and README screenshots.
- `Package.swift` defines targets and SQLite linkage; `build_app.sh` packages the app.

## Build, Test, and Development Commands

Run from the repository root with Xcode Command Line Tools installed:

- `swift build`: compile a debug build.
- `swift run AIUsageWidget`: launch the menu bar app locally.
- `swift test`: run the XCTest suite.
- `swift test --filter UsageManagerTests`: run the existing test class.
- `./build_app.sh`: build release binaries and create an ad-hoc-signed `build/AI Usage Tracker.app`; replaces the previous bundle and rewrites `Entitlements.plist`.
- `open "build/AI Usage Tracker.app"`: launch the packaged app.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, same-line opening braces, `UpperCamelCase` types, and `lowerCamelCase` properties and methods. Use descriptive filenames such as `CodexDataReader.swift` and `CodexDetailView.swift`. Keep provider parsing in services and presentation in views. Reuse `DesignSystem.swift` and `Components.swift` for shared UI. No formatter or linter configuration is checked in.

## Testing Guidelines

Use XCTest with `test`-prefixed methods describing observable behavior. Add regression cases for quota parsing, aggregation, date boundaries, and unavailable data. Prefer synthetic payloads and explicit dates/calendars. No coverage threshold is configured. The optional `ANTIGRAVITY_INTEGRATION=1 swift test` check requires a working signed-in `agy` CLI and recent local history. For UI changes, manually verify the menu bar and affected popovers.

## Commit & Pull Request Guidelines

History uses concise imperative subjects, such as `Add Google Antigravity usage support`; follow that convention. Keep changes focused. Include a PR description, relevant issue links, verification commands/results, and screenshots for UI changes.

## Version & Release Workflow

For every implemented app change, complete the version and release flow before handing it off. Use a release-triggering commit subject, push or merge the change into `main`, and verify that the Semantic Release workflow creates the next SemVer tag and GitHub release and increments `BUILD_NUMBER`. Then sync the release commit locally, run `./build_app.sh`, restart `build/AI Usage Tracker.app`, and verify the running bundle has the new version and build. See the automated versioning section in `README.md` for commit types and commands. If publishing is blocked, report the blocker and the version that is actually running.

## Security & Configuration

Keep provider databases read-only. Never commit authentication files, tokens, or personal session logs from `~/.claude`, `~/.codex`, or `~/.gemini`. Use sanitized fixtures and preserve the app’s local-data architecture.
