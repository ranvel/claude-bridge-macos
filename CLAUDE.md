# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Claude Bridge is a native macOS menu-bar app that serves nine MCP tools over Streamable HTTP on loopback (protocol version 2025-06-18). It's a Swift rewrite of a Python stdio server. The key differentiator: the project root is live, mutable server state — pick a new folder from the menu bar and all tool calls retarget without restarting anything.

**Do not connect Claude Code to this server as an MCP client.** Claude Code already has direct filesystem access; routing operations through Bridge adds a pointless network hop. This server is for MCP clients that lack native filesystem access.

## Build

Xcode project (primary):
```sh
xcodebuild -scheme "Claude Bridge" -configuration Debug build
```

No external dependencies. Builds against Apple frameworks only: AppKit, SwiftUI, Network, Foundation.

Requires macOS 13+ (Ventura). The app runs as `.accessory` (menu-bar only, no Dock icon).

## Architecture

All state flows through one object: `BridgeState` (@MainActor, ObservableObject). AppDelegate creates it, SwiftUI views bind to it, and it owns the server lifecycle.

The server runs on a dedicated DispatchQueue (`surf.ranvel.ClaudeBridge.http`). The only shared state between the main thread and the server queue is `CurrentRoot` — a thread-safe holder protected by NSLock. The UI writes it; the server reads it.

**Request flow:** `NWListener` accepts connection → `HTTPServer` parses raw HTTP (hand-rolled, not URLSession) → routes to `MCPHandler` for JSON-RPC dispatch → `Tools` executes the tool → response written as `200 OK` + JSON body on the same connection (no streaming, no SSE upgrade — all tools are single-request/single-response).

**Stateless transport:** The server is fully stateless — no `Mcp-Session-Id` is issued or validated. Every request is self-contained. Inbound session ID headers from clients that remember a previous session are accepted and ignored (no 400, no 404). `DELETE /mcp` returns 204 unconditionally. `MCP-Protocol-Version` header is accepted and ignored. This eliminates the "stale session" 404s that previously stranded clients on app restart.

**Path safety model:** All file access goes through `PathSafety.safeResolve`, which canonicalizes paths and rejects anything that escapes the project root. Doc names resolve with `.md` fallback. Binary extensions and large files (>5MB) are skipped. Search caps at 50 results.

**The nine tools** split into two groups:
- **Docs** (read/write, scoped to `<root>/docs/`): list_docs, read_doc, write_doc, update_doc, delete_doc
- **Project** (read-only): read_file, list_directory, search_files, get_project_index

## Key patterns

- Settings persist via UserDefaults, not files. Keys are in `BridgeState.Key`.
- `SkillInstaller` finds git by checking `/opt/local/bin/git`, `/usr/bin/git`, Xcode CLT path, then falls back to `/usr/bin/env git`. No Homebrew assumption.
- Errors use `BridgeError` (a simple struct with a `message` string), not an enum.
- Tool results are `ToolResult` — one or more text blocks plus an `isError` flag. Emoji prefixes (📂📄🔍✅❌🗑️) match the Python original and are intentional.
- The `Skip` enum in PathSafety.swift holds all skip lists (directories, extensions, size cap, search cap).
