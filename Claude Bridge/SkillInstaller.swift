//
//  SkillInstaller.swift
//  ClaudeBridge
//
//  Detects whether the configurable "index-project" skill is installed and,
//  if not, installs it from a configurable GitHub repo via `git clone`
//  (or refreshes it via `git pull`). Kept adaptable on purpose: repo URL,
//  skills directory, and folder name are all user-settable.
//

import Foundation

struct SkillInstaller {
	/// Where skills live (e.g. ~/.claude/skills). Tilde is expanded.
	let skillsDirectory: String
	/// Folder name for this skill (e.g. "index-project").
	let folderName: String
	/// GitHub repo URL to clone (e.g. https://github.com/ranvel/index-project-skill.git).
	let repoURL: String

	private var skillsURL: URL {
		URL(fileURLWithPath: (skillsDirectory as NSString).expandingTildeInPath, isDirectory: true)
	}

	var skillFolderURL: URL {
		skillsURL.appendingPathComponent(folderName, isDirectory: true)
	}

	/// Installed == the skill folder contains a SKILL.md.
	var isInstalled: Bool {
		FileManager.default.fileExists(atPath: skillFolderURL.appendingPathComponent("SKILL.md").path)
	}

	/// Clone (or pull) the skill. Throws BridgeError with stderr on failure.
	func install() throws {
		guard !repoURL.trimmingCharacters(in: .whitespaces).isEmpty else {
			throw BridgeError("No skill repo URL configured. Set one in Settings first.")
		}
		try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)

		let folderExists = FileManager.default.fileExists(atPath: skillFolderURL.path)
		if folderExists {
			// Refresh in place.
			try runGit(["-C", skillFolderURL.path, "pull", "--ff-only"])
		} else {
			try runGit(["clone", repoURL, skillFolderURL.path])
		}
	}

	// MARK: - git plumbing

	private func runGit(_ args: [String]) throws {
		let proc = Process()
		if let gitPath = Self.findGit() {
			proc.executableURL = URL(fileURLWithPath: gitPath)
			proc.arguments = args
		} else {
			// Fall back to resolving git via PATH.
			proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
			proc.arguments = ["git"] + args
		}

		let errPipe = Pipe()
		proc.standardError = errPipe
		proc.standardOutput = Pipe()

		do {
			try proc.run()
		} catch {
			throw BridgeError("Could not launch git: \(error.localizedDescription)")
		}
		proc.waitUntilExit()

		if proc.terminationStatus != 0 {
			let data = errPipe.fileHandleForReading.readDataToEndOfFile()
			let msg = String(data: data, encoding: .utf8) ?? "git exited \(proc.terminationStatus)"
			throw BridgeError("git failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
		}
	}

	/// Find git without assuming Homebrew. Checks common MacPorts / system /
	/// Xcode locations; returns nil to let the caller fall back to PATH.
	private static func findGit() -> String? {
		let candidates = [
			"/opt/local/bin/git",                 // MacPorts
			"/usr/bin/git",                        // system / Xcode shim
			"/Library/Developer/CommandLineTools/usr/bin/git",
		]
		for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
			return c
		}
		return nil
	}
}
