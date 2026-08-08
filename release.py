#!/usr/bin/env python3
"""Claude Bridge release tool — Conductor (spec v1) over GitHub, nothing else.

Ported from muwav's release.py choreography, minus everything Claude Bridge
doesn't have: no CDN, no droplet, no legacy banner manifest, no changelog
site. GitHub is the ONLY origin (decided: R, 2026-08-07): the manifest lives
at the repo root and is served via raw.githubusercontent.com; artifacts live
in GitHub Releases. No fallback_url — deliberately omitted, do not add one.

	release   version-gate -> archive -> export (Developer ID) -> verify ->
	          notarize + staple (app, then DMG) -> sha256 ->
	          GitHub Release (tag + DMG asset) -> commit manifest.json to main
	recall    re-point manifest.json at a previously published version
	          (Conductor never downgrades; it alerts affected users loudly —
	          moving them forward requires shipping a fixed build)
	status    local manifest vs live raw manifest vs pbxproj versions

	./release.py release --dry-run     # build + verify, upload nothing
	./release.py release
	./release.py recall                # previous published version
	./release.py recall 1.2
	./release.py status

The version gate runs FIRST, against the currently published manifest:
Conductor refuses downgrades unconditionally, so a same-version or downgrade
release must be impossible at the source, not discovered client-side. Bump
MARKETING_VERSION and CURRENT_PROJECT_VERSION in Xcode before releasing.

conductor.json ships in the app bundle (Claude Bridge/conductor.json, an
Xcode synchronized-folder resource) so it sits INSIDE the code seal — baked
in before signing, same lesson as muwav MUW-354. release.py only polices it.

Secrets live in the macOS keychain, never on disk:
	xcrun notarytool store-credentials claude-bridge-notary \
	    --apple-id you@example.com --team-id F252L9GUBW
	security add-generic-password -s claude-bridge-github -a release -w
	    # ^ a GitHub token with repo scope (falls back to `git credential fill`)

Dry-run note: --dry-run builds, exports, verifies signing, packages, and
hashes — but skips notarization (an upload to Apple) and all publishing, so
staple/Gatekeeper checks are skipped with a warning.
"""

import argparse
import datetime
import hashlib
import json
import plistlib
import shlex
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# macOS system Python wires no CA bundle into urllib; point at the OS bundle.
_CAFILE = "/etc/ssl/cert.pem"
TLS_CTX = ssl.create_default_context(
	cafile=_CAFILE if Path(_CAFILE).exists() else None)

SCRIPT_DIR = Path(__file__).resolve().parent

CONFIG = {
	"scheme": "Claude Bridge",
	"app_name": "Claude Bridge",
	"bundle_id": "com.ranvel.Claude-Bridge",
	"team_id": "F252L9GUBW",

	# GitHub — the only origin. The repo is claude-bridge-macos (the brief's
	# example URLs said claude-bridge; the real remote wins).
	"github_owner": "ranvel",
	"github_repo": "claude-bridge-macos",
	"github_remote": "github",   # git remote name that points at GitHub
	"main_branch": "main",
	"tag_prefix": "v",
	"dmg_prefix": "ClaudeBridge",

	# Manifest: committed at the repo root, served raw. Stable URL across
	# releases; a recall is just a git commit. raw.githubusercontent caches
	# ~5 minutes — acceptable recall latency (decided: R, 2026-08-07).
	"manifest_file": "manifest.json",
	"update_url": "https://raw.githubusercontent.com/ranvel/claude-bridge-macos/main/manifest.json",
	"vendor_url": "https://github.com/ranvel/claude-bridge-macos",

	# Matches MACOSX_DEPLOYMENT_TARGET in the pbxproj (verified 2026-08-07).
	"min_system_version": "15.7",

	"notary_profile": "claude-bridge-notary",
	"build_dir": "build/release",
}


# ---------------------------------------------------------------------------
# console helpers
# ---------------------------------------------------------------------------
def say(msg):
	print(msg)


def warn(msg):
	print(f"⚠️  {msg}", file=sys.stderr)


def die(msg, code=1):
	print(f"❌ {msg}", file=sys.stderr)
	sys.exit(code)


def run(cmd, **kw):
	say("   · " + " ".join(shlex.quote(str(c)) for c in cmd))
	return subprocess.run([str(c) for c in cmd], check=True, **kw)


# ---------------------------------------------------------------------------
# versions + the gate
# ---------------------------------------------------------------------------
def parse_version(v):
	"""'1.3' -> (1, 3); tolerant of any component count."""
	try:
		return tuple(int(p) for p in str(v).split("."))
	except ValueError:
		die(f"unparseable version {v!r} — expected dotted integers like 1.3")


def check_version_gate(version, build, published):
	"""Pure gate logic (unit-tested in Tests/release_tests.py).

	`published` is the currently published manifest dict, or None for a
	first release. Returns None if the release may proceed, else a string
	explaining the refusal. Rules: the build number must strictly increase
	(it is the global monotonic axis) and the version must not decrease.
	"""
	if published is None:
		return None
	pub_version = published.get("version")
	pub_build = int(published.get("build", 0))
	if build <= pub_build:
		return (f"CURRENT_PROJECT_VERSION {build} <= published build {pub_build}. "
		        "Conductor refuses downgrades unconditionally — bump it in Xcode.")
	if parse_version(version) < parse_version(pub_version):
		return (f"MARKETING_VERSION {version} < published version {pub_version}. "
		        "Versions only go up.")
	return None


def make_manifest(version, build, sha256, filename):
	url = (f"https://github.com/{CONFIG['github_owner']}/{CONFIG['github_repo']}"
	       f"/releases/download/{CONFIG['tag_prefix']}{version}/{urllib.parse.quote(filename)}")
	return {
		"conductor_manifest": 1,
		"bundle_id": CONFIG["bundle_id"],
		"version": version,
		"build": str(build),  # spec wants a string
		"url": url,
		"sha256": sha256,     # lowercase hex, spec §3.1
		"min_system_version": CONFIG["min_system_version"],
	}


def dmg_name(version):
	return f"{CONFIG['dmg_prefix']}-{version}.dmg"


def build_settings_versions():
	"""MARKETING_VERSION / CURRENT_PROJECT_VERSION from xcodebuild, so the
	gate can refuse BEFORE spending minutes on archive + notarization."""
	res = subprocess.run(
		["xcodebuild", "-showBuildSettings", "-scheme", CONFIG["scheme"],
		 "-configuration", "Release"],
		capture_output=True, text=True, check=True, cwd=SCRIPT_DIR)
	settings = {}
	for line in res.stdout.splitlines():
		if " = " in line:
			k, _, v = line.strip().partition(" = ")
			settings[k] = v
	version = settings.get("MARKETING_VERSION")
	build = settings.get("CURRENT_PROJECT_VERSION")
	if not version or not build:
		die("couldn't read MARKETING_VERSION / CURRENT_PROJECT_VERSION from "
		    "xcodebuild -showBuildSettings.")
	try:
		build = int(build)
	except ValueError:
		die(f"CURRENT_PROJECT_VERSION ({build!r}) isn't an integer.")
	return version, build


def fetch_published_manifest(allow_first):
	"""The live manifest at update_url; local manifest.json as fallback when
	the network is down. None only for an explicit first release."""
	url = CONFIG["update_url"]
	try:
		with urllib.request.urlopen(url, timeout=15, context=TLS_CTX) as r:
			return json.load(r)
	except urllib.error.HTTPError as e:
		if e.code == 404:
			local = SCRIPT_DIR / CONFIG["manifest_file"]
			if local.exists():
				warn("live manifest 404s but a local manifest.json exists — "
				     "gating against the local copy (did the push fail?).")
				return json.loads(local.read_text())
			if allow_first:
				say("\U0001f195 No published manifest — first release.")
				return None
			die("no published manifest at " + url + " and no local manifest.json. "
			    "If this is the first release, re-run with --first-release.")
		raise
	except (urllib.error.URLError, TimeoutError) as e:
		local = SCRIPT_DIR / CONFIG["manifest_file"]
		if local.exists():
			warn(f"couldn't fetch the live manifest ({e}) — gating against the "
			     "local manifest.json instead.")
			return json.loads(local.read_text())
		die(f"couldn't fetch the live manifest ({e}) and no local manifest.json "
		    "to gate against. Refusing to release blind.")


# ---------------------------------------------------------------------------
# build: archive -> export -> verify
# ---------------------------------------------------------------------------
def archive_and_export():
	build_dir = SCRIPT_DIR / CONFIG["build_dir"]
	if build_dir.exists():
		shutil.rmtree(build_dir)
	build_dir.mkdir(parents=True)
	archive = build_dir / "ClaudeBridge.xcarchive"
	export_dir = build_dir / "export"

	say("\U0001f3d7️  Archiving (Release)…")
	run(["xcodebuild", "-scheme", CONFIG["scheme"], "-configuration", "Release",
	     "archive", "-archivePath", archive, "-quiet"], cwd=SCRIPT_DIR)

	options = build_dir / "ExportOptions.plist"
	with open(options, "wb") as f:
		plistlib.dump({
			"method": "developer-id",
			"destination": "export",
			"teamID": CONFIG["team_id"],
			"signingStyle": "automatic",
		}, f)
	say("\U0001f4e6 Exporting with Developer ID Application signing…")
	run(["xcodebuild", "-exportArchive", "-archivePath", archive,
	     "-exportOptionsPlist", options, "-exportPath", export_dir, "-quiet"],
	    cwd=SCRIPT_DIR)

	app = export_dir / f"{CONFIG['app_name']}.app"
	if not app.is_dir():
		die(f"export produced no app at {app}")
	return app


def read_app_versions(app):
	with open(app / "Contents" / "Info.plist", "rb") as f:
		plist = plistlib.load(f)
	bundle_id = plist.get("CFBundleIdentifier")
	version = plist.get("CFBundleShortVersionString")
	build = plist.get("CFBundleVersion")
	if bundle_id != CONFIG["bundle_id"]:
		die(f"exported app bundle id is {bundle_id!r}, expected {CONFIG['bundle_id']!r}.")
	try:
		build = int(str(build))
	except (TypeError, ValueError):
		die(f"CFBundleVersion ({build!r}) isn't an integer.")
	return version, build


def verify_signature(app):
	say("\U0001f50e Verifying code signature…")
	run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app],
	    stderr=subprocess.DEVNULL)
	res = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)],
	                     capture_output=True, text=True)
	blob = res.stdout + res.stderr
	if f"TeamIdentifier={CONFIG['team_id']}" not in blob:
		die(f"app is not signed by team {CONFIG['team_id']} — Conductor pins "
		    "the Team ID and will refuse this artifact. Export with the "
		    "Developer ID Application identity.")
	if "Authority=Developer ID Application" not in blob:
		die("app is not Developer ID-signed (development/ad-hoc identity?). "
		    "Conductor refuses artifacts that can't pass Gatekeeper.")
	say("✅ Signed by Developer ID, team " + CONFIG["team_id"])


def verify_bundled_conductor_json(app):
	"""conductor.json must be under the code seal with exactly the URLs the
	shipped bundle will poll forever. release.py can't fix it — only refuse."""
	p = app / "Contents" / "Resources" / "conductor.json"
	if not p.is_file():
		die("no Contents/Resources/conductor.json in the exported app — "
		    "Conductor will never manage this build. It should ship from "
		    "'Claude Bridge/conductor.json' via the synchronized folder.")
	try:
		cj = json.loads(p.read_text())
	except ValueError as e:
		die(f"bundled conductor.json doesn't parse: {e}")
	if cj.get("conductor") != 1:
		die(f"bundled conductor.json format is {cj.get('conductor')!r}, expected 1.")
	if cj.get("update_url") != CONFIG["update_url"]:
		die(f"bundled update_url is {cj.get('update_url')!r}, expected "
		    f"{CONFIG['update_url']!r} — a shipped bundle polls that URL forever.")
	if "fallback_url" in cj:
		die("bundled conductor.json carries a fallback_url — GitHub-only, no "
		    "fallback, is a decided constraint for this project (R, 2026-08-07).")
	say("✅ conductor.json present, format 1, URLs match.")


def verify_notarized(app, skipped):
	if skipped:
		warn("dry-run: skipping Gatekeeper/staple validation (app was not notarized).")
		return
	res = subprocess.run(
		["spctl", "--assess", "--verbose=4", "--type", "execute", str(app)],
		capture_output=True, text=True)
	blob = res.stdout + res.stderr
	if res.returncode != 0:
		die("Gatekeeper rejected the app (spctl --assess failed):\n" + blob.strip())
	if "Notarized" not in blob:
		warn("Gatekeeper accepted the app but it doesn't read as Notarized — "
		     "double-check the notarization step.")
	run(["xcrun", "stapler", "validate", app])
	say("✅ App is signed, notarized, and stapled.")


# ---------------------------------------------------------------------------
# notarization + packaging
# ---------------------------------------------------------------------------
def notarize(path, dry):
	"""Submit a zip or DMG to Apple and wait. Staple is the caller's job
	(you staple the app/DMG, not the submission zip)."""
	if dry:
		say(f"[dry-run] notarytool submit {path}")
		return
	say(f"\U0001f680 Notarizing {path.name} (waits for Apple)…")
	run(["xcrun", "notarytool", "submit", path,
	     "--keychain-profile", CONFIG["notary_profile"], "--wait"])


def notarize_app(app, dry):
	if dry:
		say("[dry-run] would notarize + staple the app")
		return
	with tempfile.TemporaryDirectory() as td:
		zip_path = Path(td) / "app.zip"
		run(["ditto", "-c", "-k", "--keepParent", app, zip_path])
		notarize(zip_path, dry)
	run(["xcrun", "stapler", "staple", app])


def make_dmg(app, version):
	dmg = SCRIPT_DIR / CONFIG["build_dir"] / dmg_name(version)
	say("\U0001f4bf Packaging DMG…")
	with tempfile.TemporaryDirectory() as td:
		staging = Path(td) / "staging"
		staging.mkdir()
		run(["ditto", app, staging / app.name])
		(staging / "Applications").symlink_to("/Applications")
		run(["hdiutil", "create", "-volname", CONFIG["app_name"],
		     "-srcfolder", staging, "-ov", "-format", "UDZO", dmg])
	return dmg


def notarize_dmg(dmg, dry):
	if dry:
		say("[dry-run] would notarize + staple the DMG")
		return
	notarize(dmg, dry)
	run(["xcrun", "stapler", "staple", dmg])
	run(["xcrun", "stapler", "validate", dmg])


def sha256_file(path):
	h = hashlib.sha256()
	with open(path, "rb") as f:
		for chunk in iter(lambda: f.read(1 << 20), b""):
			h.update(chunk)
	return h.hexdigest()


# ---------------------------------------------------------------------------
# GitHub (REST API — gh isn't installed on this machine)
# ---------------------------------------------------------------------------
def github_token():
	res = subprocess.run(
		["security", "find-generic-password", "-s", "claude-bridge-github",
		 "-a", "release", "-w"],
		capture_output=True, text=True)
	if res.returncode == 0 and res.stdout.strip():
		return res.stdout.strip()
	# fall back to whatever credential helper git itself uses for github.com
	res = subprocess.run(
		["git", "credential", "fill"],
		input="protocol=https\nhost=github.com\n\n",
		capture_output=True, text=True)
	for line in res.stdout.splitlines():
		if line.startswith("password="):
			return line.partition("=")[2]
	die("no GitHub token. Add one:\n"
	    "  security add-generic-password -s claude-bridge-github -a release -w")


def gh_api(token, url, data=None, method=None, content_type="application/json"):
	body = None
	if data is not None:
		body = data if isinstance(data, bytes) else json.dumps(data).encode()
	req = urllib.request.Request(
		url, data=body, method=method or ("POST" if body else "GET"),
		headers={
			"Authorization": f"Bearer {token}",
			"Accept": "application/vnd.github+json",
			"Content-Type": content_type,
			"X-GitHub-Api-Version": "2022-11-28",
		})
	with urllib.request.urlopen(req, context=TLS_CTX) as r:
		return json.load(r)


def publish_github_release(version, build, dmg, dry):
	tag = f"{CONFIG['tag_prefix']}{version}"
	repo = f"{CONFIG['github_owner']}/{CONFIG['github_repo']}"
	if dry:
		say(f"[dry-run] git tag {tag} && git push {CONFIG['github_remote']} {tag}")
		say(f"[dry-run] POST /repos/{repo}/releases (tag {tag}) + upload {dmg.name}")
		return
	token = github_token()

	say(f"\U0001f516 Tagging {tag}…")
	existing = subprocess.run(
		["git", "-C", str(SCRIPT_DIR), "rev-parse", tag],
		capture_output=True, text=True)
	if existing.returncode == 0:
		tag_commit = subprocess.run(
			["git", "-C", str(SCRIPT_DIR), "rev-parse", f"{tag}^{{}}"],
			capture_output=True, text=True, check=True).stdout.strip()
		head = subprocess.run(
			["git", "-C", str(SCRIPT_DIR), "rev-parse", "HEAD"],
			capture_output=True, text=True, check=True).stdout.strip()
		if tag_commit == head:
			say(f"   tag {tag} already exists at HEAD, reusing")
		else:
			die(f"tag {tag} exists but points at {tag_commit[:7]}, not HEAD. "
			    f"Delete it manually (git tag -d {tag}) or bump the version.")
	else:
		run(["git", "-C", SCRIPT_DIR, "tag", "-a", tag, "-m",
		     f"{CONFIG['app_name']} {version} (build {build})"])
	run(["git", "-C", SCRIPT_DIR, "push", CONFIG["github_remote"], tag])

	say("\U0001f4e3 Creating the GitHub Release…")
	rel = gh_api(token, f"https://api.github.com/repos/{repo}/releases", data={
		"tag_name": tag,
		"name": f"{CONFIG['app_name']} {version}",
		"body": f"{CONFIG['app_name']} {version} (build {build}). "
		        "Signed and notarized; updates delivered via Conductor.",
	})
	upload_url = rel["upload_url"].split("{")[0]
	say(f"☁️  Uploading {dmg.name} ({dmg.stat().st_size:,} bytes)…")
	gh_api(token,
	       upload_url + "?" + urllib.parse.urlencode({"name": dmg.name}),
	       data=dmg.read_bytes(), content_type="application/octet-stream")
	say(f"✅ Release published: https://github.com/{repo}/releases/tag/{tag}")


def commit_manifest(manifest, message, dry):
	path = SCRIPT_DIR / CONFIG["manifest_file"]
	body = json.dumps(manifest, indent="\t") + "\n"
	if dry:
		say("[dry-run] manifest.json would be:\n" + body.rstrip())
		say(f"[dry-run] git commit {CONFIG['manifest_file']} && push "
		    f"{CONFIG['github_remote']} {CONFIG['main_branch']}")
		return
	path.write_text(body)
	run(["git", "-C", SCRIPT_DIR, "add", CONFIG["manifest_file"]])
	run(["git", "-C", SCRIPT_DIR, "commit", "-m", message, "--only",
	     CONFIG["manifest_file"]])
	run(["git", "-C", SCRIPT_DIR, "push", CONFIG["github_remote"],
	     CONFIG["main_branch"]])
	say(f"\U0001f680 Manifest live (≤~5 min raw cache): {CONFIG['update_url']}")


# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------
def cmd_release(args):
	# 1. the gate, before any expensive work
	version, build = build_settings_versions()
	say(f"\U0001f3f7️  Building v{version} (build {build})")
	published = fetch_published_manifest(args.first_release)
	refusal = check_version_gate(version, build, published)
	if refusal:
		die(refusal)

	# 2. build + verify
	app = archive_and_export()
	app_version, app_build = read_app_versions(app)
	if (app_version, app_build) != (version, build):
		die(f"exported app says v{app_version} (build {app_build}) but build "
		    f"settings said v{version} (build {build}) — version drift.")
	verify_signature(app)
	verify_bundled_conductor_json(app)

	# 3. notarize the app, then package + notarize the DMG
	notarize_app(app, args.dry_run)
	verify_notarized(app, skipped=args.dry_run)
	dmg = make_dmg(app, version)
	notarize_dmg(dmg, args.dry_run)

	sha = sha256_file(dmg)
	say(f"\U0001f522 sha256 {sha}")
	manifest = make_manifest(version, build, sha, dmg.name)

	# 4. publish: release first, manifest second — the manifest must never
	# advertise an artifact that isn't downloadable yet.
	publish_github_release(version, build, dmg, args.dry_run)
	commit_manifest(manifest,
	                f"release: {CONFIG['tag_prefix']}{version} (build {build})",
	                args.dry_run)
	say("")
	if args.dry_run:
		say(f"✨ Dry run complete. Artifact at {dmg} — nothing uploaded.")
	else:
		say(f"✨ v{version} (build {build}) released and advertised.")


def manifest_history():
	"""(commit, manifest) pairs for every commit that touched manifest.json,
	newest first — GitHub Releases plus git history ARE the release records."""
	res = subprocess.run(
		["git", "-C", str(SCRIPT_DIR), "log", "--format=%H", "--",
		 CONFIG["manifest_file"]],
		capture_output=True, text=True, check=True)
	out = []
	for commit in res.stdout.split():
		show = subprocess.run(
			["git", "-C", str(SCRIPT_DIR), "show",
			 f"{commit}:{CONFIG['manifest_file']}"],
			capture_output=True, text=True)
		if show.returncode != 0:
			continue
		try:
			out.append((commit, json.loads(show.stdout)))
		except ValueError:
			continue
	return out


def select_recall_target(history, current, want_version=None):
	"""Pick the manifest to re-advertise from (commit, manifest) history,
	newest first. Pure — unit-tested in Tests/release_tests.py."""
	for _commit, m in history:
		if want_version:
			if m.get("version") == want_version and m != current:
				return m
		elif m.get("version") != current.get("version"):
			return m
	return None


def cmd_recall(args):
	local = SCRIPT_DIR / CONFIG["manifest_file"]
	if not local.exists():
		die("no manifest.json — nothing has been released yet.")
	current = json.loads(local.read_text())
	say(f"\U0001f4cb Currently advertising v{current.get('version')} "
	    f"(build {current.get('build')}).")

	target = select_recall_target(manifest_history(), current, args.version)
	if target is None:
		die("no earlier published version found in manifest.json history"
		    + (f" matching {args.version!r}" if args.version else "")
		    + ". Ship a fixed build instead.")

	say(f"⛔ Re-pointing the manifest at v{target['version']} "
	    f"(build {target['build']}).")
	commit_manifest(
		target,
		f"recall: re-point manifest at {CONFIG['tag_prefix']}{target['version']}",
		args.dry_run)
	say("   Conductor alerts users on the recalled build loudly and never "
	    "silently downgrades — ship a fixed build to move them forward.")


def cmd_status(args):
	version, build = build_settings_versions()
	say(f"\U0001f3f7️  Working tree: v{version} (build {build})")
	local = SCRIPT_DIR / CONFIG["manifest_file"]
	if local.exists():
		say("\U0001f4cb Local manifest:  " + json.dumps(json.loads(local.read_text())))
	else:
		say("\U0001f4cb No local manifest.json yet.")
	try:
		with urllib.request.urlopen(CONFIG["update_url"], timeout=10,
		                            context=TLS_CTX) as r:
			live = json.load(r)
		say("\U0001f310 Live manifest:   " + json.dumps(live))
		if local.exists() and live != json.loads(local.read_text()):
			warn("local and live manifests differ (raw cache is ~5 min, or push pending).")
	except Exception as e:  # noqa: BLE001
		warn(f"couldn't fetch live manifest: {e}")


# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------
def build_parser():
	common = argparse.ArgumentParser(add_help=False)
	common.add_argument("--dry-run", action="store_true",
	                    help="build + verify; skip notarization and all publishing")

	p = argparse.ArgumentParser(description="Claude Bridge release tool (Conductor over GitHub)")
	sub = p.add_subparsers(dest="cmd", required=True)

	r = sub.add_parser("release", parents=[common],
	                   help="archive, notarize, package, publish, advertise")
	r.add_argument("--first-release", action="store_true",
	               help="allow releasing with no published manifest")
	r.set_defaults(func=cmd_release)

	rc = sub.add_parser("recall", parents=[common],
	                    help="re-point the manifest at a previous version")
	rc.add_argument("version", nargs="?",
	                help="version to re-advertise (default: the previous one)")
	rc.set_defaults(func=cmd_recall)

	st = sub.add_parser("status", parents=[common], help="local vs live manifest")
	st.set_defaults(func=cmd_status)
	return p


def main():
	args = build_parser().parse_args()
	args.func(args)


if __name__ == "__main__":
	main()
