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

Regression tests (no XCTest target — `Tests/run.sh` compiles `PathSafety.swift` + `Tools.swift` directly with swiftc and runs assertions against a temp fixture):
```sh
./Tests/run.sh
```

## Architecture

All state flows through one object: `BridgeState` (@MainActor, ObservableObject). AppDelegate creates it, SwiftUI views bind to it, and it owns the server lifecycle.

The server runs on a dedicated DispatchQueue (`surf.ranvel.ClaudeBridge.http`). The only shared state between the main thread and the server queue is `CurrentRoot` — a thread-safe holder protected by NSLock. The UI writes it; the server reads it.

**Request flow:** `NWListener` accepts connection → `HTTPServer` parses raw HTTP (hand-rolled, not URLSession) → routes to `MCPHandler` for JSON-RPC dispatch → `Tools` executes the tool → response written as `200 OK` + JSON body on the same connection (no streaming, no SSE upgrade — all tools are single-request/single-response).

**Stateless transport:** The server is fully stateless — no `Mcp-Session-Id` is issued or validated. Every request is self-contained. Inbound session ID headers from clients that remember a previous session are accepted and ignored (no 400, no 404). `DELETE /mcp` returns 204 unconditionally. `MCP-Protocol-Version` header is accepted and ignored. This eliminates the "stale session" 404s that previously stranded clients on app restart.

**Path safety model:** All file access goes through `PathSafety.safeResolve`, which canonicalizes paths and rejects anything that escapes the project root. Doc names resolve with `.md` fallback. Search caps at 50 results.

**Binary handling:** A file is binary if its extension is in `Skip.extensions` (compiled artifacts + assets/media/archives) or its first 8 KB contain a NUL byte (`PathSafety.isBinary` — extension check first, bounded sniff second; whole file never read). Binary *content* is never read or searched, but binaries never disappear: `search_files` matches the pattern against binary file *names* (`📦 path (binary — name match)`) and appends a footer reporting how many binary files / how many MB were not content-searched; `read_file` on a binary returns a non-error metadata block (magic-number type, size, mtime) instead of a dead-end. `Skip.compiledExtensions` (the artifact subset) is what `list_directory` filters on, so listings still show assets.

**Ranged reads:** `read_file` and `read_doc` take optional `offset` (1-based line) and `limit` (line count). Ranged responses carry a `(lines A–B of N)` header and a continuation footer. Files over `Skip.maxReadSize` (5 MB) *require* a range (the error says so); ranged reads stream incrementally and never load the whole file.

**Batch edits:** `update_doc` accepts either a single `old_text`/`new_text` pair or an `edits` array (exactly one form per call). Edits apply sequentially — each against the result of the previous — and are validated against the evolving in-memory copy before anything is written: any failure (not found / not unique) rejects the whole batch with the failing edit's index, and the document is untouched. Atomic: never partially applied.

**The nine tools** split into two groups:
- **Docs** (read/write, scoped to `<root>/docs/`): list_docs, read_doc, write_doc, update_doc, delete_doc
- **Project** (read-only): read_file, list_directory, search_files, get_project_index

## Releases & updates

Updates are delivered by Conductor (no Sparkle, no in-app update code — the
bridge's only network surface stays localhost). The integration is two JSON
files: `Claude Bridge/conductor.json` (a synchronized-folder bundle resource,
lands at `Contents/Resources/conductor.json`) and `manifest.json` at the repo
root, served via `https://raw.githubusercontent.com/ranvel/claude-bridge-macos/main/manifest.json`.
GitHub is the only origin — artifacts live in GitHub Releases, no fallback URL, by decision.

**Invariant: conductor.json must be inside the code seal.** It ships as a
bundle resource so it is baked in *before* signing — a tampered copy breaks
the signature the next update is verified against. Never generate or patch it
post-build.

`release.py` is the pipeline: version gate (refuses same-version/downgrade
releases against the published manifest) → archive → Developer ID export →
notarize + staple (app, then DMG) → sha256 → GitHub Release → commit
manifest.json. `./release.py release --dry-run` builds and verifies without
uploading; `recall` re-points the manifest at a previous version. Logic tests:
`python3 Tests/release_tests.py`.

## Key patterns

- Settings persist via UserDefaults, not files. Keys are in `BridgeState.Key`.
- `SkillInstaller` finds git by checking `/opt/local/bin/git`, `/usr/bin/git`, Xcode CLT path, then falls back to `/usr/bin/env git`. No Homebrew assumption.
- Errors use `BridgeError` (a simple struct with a `message` string), not an enum.
- Tool results are `ToolResult` — one or more text blocks plus an `isError` flag. Emoji prefixes (📂📄🔍✅❌🗑️) match the Python original and are intentional.
- The `Skip` enum in PathSafety.swift holds all skip lists (directories, extensions, size cap, search cap).
