# Cici Findings — Conductor Adoption (implemented 2026-08-07)

All three targets from `cici-brief-conductor-adoption.md` shipped. The full dry-run pipeline (archive → Developer ID export → verify → package → hash → manifest preview) ran green on this machine.

## Recon corrections to the brief

1. **The GitHub repo is `ranvel/claude-bridge-macos`, not `ranvel/claude-bridge`.** The brief's example URLs used the shorter name; the real `github` remote wins. All URLs (update_url, vendor_url, release download URLs) use `claude-bridge-macos`.
2. **`min_system_version` is `15.7`**, not the brief's 15.6 guess — that's `MACOSX_DEPLOYMENT_TARGET` in the pbxproj.
3. **No pbxproj edit was needed for conductor.json.** The project uses Xcode 16 file-system-synchronized groups (`objectVersion = 77`), so `Claude Bridge/conductor.json` is picked up as a bundle resource automatically. Verified in the built product: it lands at `Contents/Resources/conductor.json`, and since resource copy precedes signing it sits inside the code seal.
4. **Notarization did not exist in the manual flow** (brief asked to verify) — no `notarytool` usage anywhere in repo history. `release.py` adds it: app is zipped, notarized, and stapled first, then the DMG is built from the stapled app and itself notarized + stapled, so both the DMG and a dragged-out app validate offline.
5. **`gh` CLI is not installed** on this machine. `release.py` talks to the GitHub REST API directly with a token from the keychain (`claude-bridge-github` service, muwav-style), falling back to `git credential fill`.

## Design notes

- **Recall needs no state files.** GitHub Releases plus the git history of `manifest.json` *are* the release records — `recall` walks `git log -- manifest.json`, re-points at the previous (or named) version's manifest, commits, and pushes. No `artifacts.json` sidecar like muwav needed.
- **Publish order:** GitHub Release (tag + DMG asset) first, manifest commit second — the manifest must never advertise an artifact that isn't downloadable yet.
- **Version gate runs before any expensive work**, reading `xcodebuild -showBuildSettings`, and gates against the *live* manifest (local `manifest.json` only as a network-down fallback; `--first-release` for bootstrap). Build number must strictly increase; version must never decrease.
- **`release.py` polices the bundled conductor.json** (present, format 1, exact update_url, *no* fallback_url) and refuses to ship a build Conductor would ignore — the MUW-354 lesson, enforced at release time.

## Per-behavior test accounting (brief: test or one-line justification)

| Behavior | Status |
|---|---|
| Version gate (8 cases incl. same-version, downgrade, forgotten build bump) | Unit-tested — `Tests/release_tests.py` |
| Manifest shape (required fields, string build, lowercase sha256, URL, min_system_version) | Unit-tested |
| Recall selection (default previous, explicit version, not-found) + git-history reader | Unit-tested (history test uses a real temp git repo) |
| Archive → Developer ID export → signature/team verify → conductor.json police → DMG → sha256 | Exercised live via `./release.py release --dry-run` (passed 2026-08-07; TeamIdentifier F252L9GUBW confirmed) |
| Notarization + staple | Not auto-tested: it is an upload to Apple's notary service; dry-run deliberately skips it. The pipeline validates it on the first real release (`spctl --assess`, `stapler validate` on both app and DMG). |
| GitHub Release create + asset upload, manifest commit/push | Not auto-tested: would publish a real public release. Dry-run prints the exact calls; the code paths are thin wrappers over the REST API and git. |

## First-release checklist (manual, per the brief's Testing section)

These need a real signed+notarized artifact and the Conductor GUI — dev mode relaxes transport only:

1. One-time setup: `xcrun notarytool store-credentials claude-bridge-notary --apple-id … --team-id F252L9GUBW` and a GitHub token in the keychain (`security add-generic-password -s claude-bridge-github -a release -w`).
2. Bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in Xcode, then `./release.py release --first-release`.
3. `conductor --dev-mode com.ranvel.Claude-Bridge` against a local `python3 -m http.server` manifest: full notify → verify → swap.
4. Downgrade refusal: serve a lower-version manifest → Conductor refuses.
5. Tamper: flip one byte of the DMG → sha256/verification failure, no swap.
6. Recall: `./release.py recall` → loud user notice, no silent downgrade.
7. Restart survival: MCP client mid-conversation across the update swap — the stateless transport means nothing worse than a brief connection retry.
