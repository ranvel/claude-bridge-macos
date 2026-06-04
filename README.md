# Claude Bridge 🌉 (macOS menu-bar app)

A native macOS menu-bar app that serves the **Claude Bridge** MCP tools over a
local **Streamable HTTP** transport. It gives Claude (Claude Code, or any MCP client
that speaks the SSE transport) structured, scoped access to a project's docs and
source files — and lets you **switch the active project root on the fly** without
restarting anything.

This is a Swift rewrite of the original `server.py` stdio server. The behavior of
the nine tools is preserved; what changed is the *shape* of the thing: a resident
menu-bar app instead of a per-project stdio subprocess.

## Why a menu-bar app instead of stdio?

A stdio MCP server has its project root baked in at spawn time (`--project-root`),
so switching projects means editing config and relaunching. As someone who hops
between repos all day, that's friction.

This version keeps the project root as **live, mutable server state**. Pick a new
folder from the menu bar and every subsequent tool call targets the new root —
the SSE connection stays up, no client reconfig. It also remembers your **last
five project roots** for one-click switching. 🗂️

## The nine tools

**Docs (read/write, scoped to `<root>/docs/`):**
`list_docs`, `read_doc`, `write_doc`, `update_doc`, `delete_doc`

**Project (read-only):**
`read_file`, `list_directory`, `search_files`, `get_project_index`

Same safety rails as the Python version: path-escape protection, binary-file
skipping, a 5 MB per-file read cap, and a 50-result search cap.

## Requirements

- macOS 13 (Ventura) or later
- A Swift toolchain — either the Xcode Command Line Tools (`xcode-select --install`)
  or a standalone Swift toolchain from swift.org
- `git` on disk (for the skill installer). The app looks in this order:
  `/opt/local/bin/git` (MacPorts), `/usr/bin/git`, the Command Line Tools path,
  and finally falls back to `/usr/bin/env git`.

No Homebrew, no external Swift packages — it builds against Apple frameworks only
(AppKit, SwiftUI, Network).

## Build & run

```sh
git clone <this-repo> claude-bridge
cd claude-bridge
xcodebuild -scheme "Claude Bridge" -configuration Release build
```

The app launches as an **accessory** (menu-bar only, no Dock icon). Look for the
🌉 item in your menu bar. On first launch it pops open and — if you don't already
have the `index-project` skill — offers to install it.


## Connect an MCP client

Make sure the Claude Bridge menu-bar app is running and the server is started
(look for the 🌉 icon in your menu bar — the popover should show a green dot
and "Listening on port 19850").

Any MCP client that speaks the Streamable HTTP transport can connect. Add the
following to your client's MCP server configuration (e.g. `mcp.json`):

```json
{
  "claude-bridge": {
    "command": "npx",
    "args": [
      "-y",
      "mcp-remote",
      "http://127.0.0.1:19850/mcp",
      "--transport",
      "http-only"
    ]
  }
}
```

> **A note on Claude Code specifically:** Claude Code already has direct,
> efficient access to the filesystem and its own tool suite. Routing those same
> operations through Claude Bridge adds a network hop and a second layer of
> tool dispatch for no practical benefit — it would be extraordinarily wasteful.
> Claude Bridge is designed for MCP clients that *don't* have native filesystem
> access, or for workflows where you want the scoped docs/ read-write surface
> without granting broader permissions.

## Picking a project root

Click **Choose Folder…** and select any project directory. From then on:

- All read-only tools resolve paths relative to that root.
- Docs tools read/write inside `<root>/docs/`.
- If `<root>/docs/` **already exists**, the popover shows a banner letting you know
  it'll be shared and **Claude gets write access** to it. ✍️
- The folder joins your **recents** list (max 5, most-recent-first). Click any
  recent to switch instantly.

## The index-project skill

`get_project_index` reads a `project-index.md` map from the project root. The
**index-project skill** teaches Claude how to build and maintain that map.

Because it's distributed as a GitHub repo, the installer is fully configurable in
**Settings**:

- **Skills directory** — where skills live (default `~/.claude/skills`)
- **Skill folder name** — the subfolder to install into (default `index-project`)
- **Skill repo URL** — the GitHub URL to clone (defaults to the
  [index-project-skill](https://github.com/ranvel/index-project-skill.git) repo;
  repoint it if you maintain your own fork)

Install does a `git clone`; if the folder already exists it does a
`git pull --ff-only` to update. The skill is considered installed when
`<skills-dir>/<folder>/SKILL.md` exists. ✅

## Settings reference

| Setting | Default | Notes |
|---|---|---|
| Port | `19850` | Apply restarts the server on the new port |
| Auto-start server | on | Starts the SSE server at launch |
| Skills directory | `~/.claude/skills` | Tilde is expanded |
| Skill folder name | `index-project` | |
| Skill repo URL | `ranvel/index-project-skill` | Repoint to use a different skill repo |

All settings and your recents/current root persist via `UserDefaults`.

## Architecture

```
main.swift            NSApplication bootstrap (.accessory policy)
AppDelegate.swift     Status item, popover, window, folder picker, onboarding
BridgeState.swift     @MainActor source of truth: root, recents, server, settings
UI/
  BridgeView.swift    SwiftUI popover/window content
  SkillInstaller.swift  git clone/pull of the index-project skill
Server/
  HTTPServer.swift    Network.framework Streamable HTTP listener (loopback only)
  MCPHandler.swift    JSON-RPC 2.0 / MCP dispatch (initialize, tools/list, tools/call)
  Tools.swift         The nine tools + thread-safe CurrentRoot holder
  PathSafety.swift    Path-escape guards, doc-name resolution, skip rules
```

## Notes & caveats

- **Not sandboxed** — by design, so it can read arbitrary project folders you choose.
- **Case-sensitive lookups**, exact-match, same as the Python original.
- The Streamable HTTP transport is hand-rolled on `Network.framework` rather than
  pulled from an SDK (keeps the dependency count at zero). If you hit a connection
  quirk, that parser is the first place to look. 🔍
