# Claude Bridge — Project Index

> Auto-maintained by Claude. Last updated: 2026-06-04

## Project Structure

### / (Root)
- `project-index.md` — This file
- `CLAUDE.md` — AI onboarding context and architecture notes
- `README.md` — Project readme with setup, tools, and architecture overview
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

### /Claude Bridge/Assets.xcassets/
Xcode asset catalog with app icon variants and accent color.

### /Claude Bridge.xcodeproj/
Xcode project configuration.

### /icon-maker/
Tooling to generate the macOS app icon set from a single 1024px source.

- `icon-maker/make-icons.sh` — Shell script: resizes Icon1024.png into .iconset via sips, then builds .icns
- `icon-maker/Icon1024.png` — Source icon at 1024x1024
- `icon-maker/MyIcon.icns` — Generated macOS icon bundle

### /.claude/
- `.claude/settings.local.json` — Local Claude Code project settings
