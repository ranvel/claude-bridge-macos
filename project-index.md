# Claude Bridge — Project Index

> Auto-maintained by Claude. Last updated: 2026-08-07

## Project Structure

### / (Root)
- `project-index.md` — This file
- `CLAUDE.md` — AI onboarding context and architecture notes
- `README.md` — Project readme with install/setup, tools, and architecture overview
- `release.py` — Release pipeline: version gate → archive → Developer ID export → notarize/staple → DMG → sha256 → GitHub Release → manifest commit; also `recall` and `status`
- `manifest.json` — Conductor update manifest (created by the first `release.py release`; served raw from GitHub)
- `LICENSE` — Project license
- `.gitignore` — Git ignore rules

### /Claude Bridge/
The macOS app source. All Swift, no external dependencies.

- `Claude Bridge/main.swift` — NSApplication bootstrap, accessory (menu-bar only) launch policy
- `Claude Bridge/AppDelegate.swift` — Status item, popover, standalone window, folder picker, first-launch onboarding
- `Claude Bridge/BridgeState.swift` — @MainActor source of truth: root, recents, server lifecycle, settings persistence
- `Claude Bridge/BridgeView.swift` — SwiftUI popover/window UI: project picker, recents, server status, skill install, settings
- `Claude Bridge/HTTPServer.swift` — Network.framework Streamable HTTP server (loopback only, MCP 2025-06-18 transport)
- `Claude Bridge/MCPHandler.swift` — JSON-RPC 2.0 dispatch for MCP methods (initialize, ping, tools/list, tools/call)
- `Claude Bridge/Tools.swift` — The nine MCP tools + thread-safe CurrentRoot holder
- `Claude Bridge/PathSafety.swift` — Path-escape guards, doc-name resolution, BridgeError, skip rules
- `Claude Bridge/SkillInstaller.swift` — Git clone/pull installer for the index-project skill
- `Claude Bridge/conductor.json` — Conductor update descriptor; ships at Contents/Resources inside the code seal (synchronized-folder resource)

### /Claude Bridge/Assets.xcassets/
Xcode asset catalog with app icon variants and accent color.

### /Claude Bridge.xcodeproj/
Xcode project configuration.

### /icon-maker/
Tooling to generate the macOS app icon set from a single 1024px source.

- `icon-maker/make-icons.sh` — Shell script: resizes Icon1024.png into .iconset via sips, then builds .icns
- `icon-maker/Icon1024.png` — Source icon at 1024x1024
- `icon-maker/MyIcon.icns` — Generated macOS icon bundle

### /Tests/
Regression tests. No XCTest target — `run.sh` compiles the tool sources directly with swiftc.

- `Tests/run.sh` — Builds and runs the Swift tool tests (PathSafety + Tools against a temp fixture)
- `Tests/main.swift` — The Swift assertions: binary awareness, ranged reads, batch edits, no-regression checks
- `Tests/release_tests.py` — Unit tests for release.py logic (version gate, manifest shape, recall selection)

### /docs/
Design briefs and findings written by Cici documenting decisions and fixes.

- `docs/cici-brief-docs-consent-alert.md` — Replace persistent docs banner with one-time consent alert
- `docs/cici-brief-docs-path-resolution.md` — Fix docs tools failing when `docs/` directory doesn't exist
- `docs/cici-brief-stateless-transport.md` — Remove session machinery to eliminate stale-session 404s
- `docs/cici-brief-file-surgery.md` — Binary awareness, ranged reads, batch edits for the tools
- `docs/cici-brief-conductor-adoption.md` — Adopt Conductor as the update channel over GitHub
- `docs/cici-findings-file-surgery.md` — File-surgery implementation findings, recon calls, perf evidence
- `docs/cici-findings-conductor-adoption.md` — Conductor adoption findings, brief corrections, first-release checklist

### /.claude/
- `.claude/settings.local.json` — Local Claude Code project settings
