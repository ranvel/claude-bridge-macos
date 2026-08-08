#!/usr/bin/env python3
"""Unit tests for release.py's pure logic (version gate, manifest shape,
recall selection, manifest history). The regression-testable surface per the
Conductor-adoption brief; the build/notarize/publish choreography is
exercised via `./release.py release --dry-run` (see the findings doc for the
per-behavior justification table).

Run:  python3 Tests/release_tests.py
"""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("release", REPO / "release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


PUBLISHED = {"conductor_manifest": 1, "version": "1.2", "build": "4"}


class VersionGate(unittest.TestCase):
	def test_first_release_passes(self):
		self.assertIsNone(release.check_version_gate("1.2", 4, None))

	def test_same_version_same_build_refused(self):
		self.assertIn("Conductor refuses downgrades",
		              release.check_version_gate("1.2", 4, PUBLISHED))

	def test_downgrade_refused(self):
		self.assertIsNotNone(release.check_version_gate("1.1", 3, PUBLISHED))

	def test_build_not_bumped_refused(self):
		# version went up but CURRENT_PROJECT_VERSION was forgotten
		self.assertIn("<= published build",
		              release.check_version_gate("1.3", 4, PUBLISHED))

	def test_version_decrease_refused_even_with_higher_build(self):
		self.assertIn("Versions only go up",
		              release.check_version_gate("1.1", 5, PUBLISHED))

	def test_same_version_higher_build_passes(self):
		self.assertIsNone(release.check_version_gate("1.2", 5, PUBLISHED))

	def test_normal_bump_passes(self):
		self.assertIsNone(release.check_version_gate("1.3", 5, PUBLISHED))

	def test_multicomponent_versions_compare_numerically(self):
		self.assertIsNone(release.check_version_gate("1.10", 5, PUBLISHED))


class ManifestShape(unittest.TestCase):
	def test_required_fields_and_types(self):
		m = release.make_manifest("1.3", 5, "ab" * 32, "ClaudeBridge-1.3.dmg")
		self.assertEqual(m["conductor_manifest"], 1)
		self.assertEqual(m["bundle_id"], "com.ranvel.Claude-Bridge")
		self.assertEqual(m["version"], "1.3")
		self.assertEqual(m["build"], "5")          # spec wants a string
		self.assertEqual(m["sha256"], "ab" * 32)   # lowercase hex preserved
		self.assertEqual(m["min_system_version"], "15.7")
		self.assertEqual(
			m["url"],
			"https://github.com/ranvel/claude-bridge-macos/releases/download/"
			"v1.3/ClaudeBridge-1.3.dmg")

	def test_dmg_name(self):
		self.assertEqual(release.dmg_name("1.3"), "ClaudeBridge-1.3.dmg")


class RecallSelection(unittest.TestCase):
	V13 = {"version": "1.3", "build": "5"}
	V12 = {"version": "1.2", "build": "4"}
	V11 = {"version": "1.1", "build": "3"}
	HISTORY = [("c3", V13), ("c2", V12), ("c1", V11)]

	def test_default_picks_previous_version(self):
		self.assertEqual(
			release.select_recall_target(self.HISTORY, self.V13), self.V12)

	def test_explicit_version(self):
		self.assertEqual(
			release.select_recall_target(self.HISTORY, self.V13, "1.1"), self.V11)

	def test_no_earlier_version(self):
		self.assertIsNone(
			release.select_recall_target([("c1", self.V11)], self.V11))

	def test_explicit_version_not_found(self):
		self.assertIsNone(
			release.select_recall_target(self.HISTORY, self.V13, "0.9"))


class ManifestHistory(unittest.TestCase):
	def test_reads_git_history_newest_first(self):
		with tempfile.TemporaryDirectory() as td:
			repo = Path(td)
			def git(*a):
				subprocess.run(["git", "-C", str(repo), *a], check=True,
				               capture_output=True)
			git("init", "-q")
			git("config", "user.email", "t@t")
			git("config", "user.name", "t")
			for ver in ("1.1", "1.2"):
				(repo / "manifest.json").write_text(
					json.dumps({"version": ver, "build": ver[-1]}))
				git("add", "manifest.json")
				git("commit", "-q", "-m", f"release {ver}")

			old_dir = release.SCRIPT_DIR
			release.SCRIPT_DIR = repo
			try:
				hist = release.manifest_history()
			finally:
				release.SCRIPT_DIR = old_dir

			self.assertEqual([m["version"] for _c, m in hist], ["1.2", "1.1"])


if __name__ == "__main__":
	unittest.main(verbosity=2)
