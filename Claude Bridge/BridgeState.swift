//
//  BridgeState.swift
//  ClaudeBridge
//
//  The app's single source of truth (main thread). Owns the server, the
//  thread-safe root holder, the recent-projects list, and all settings.
//  SwiftUI views bind to its @Published properties; AppDelegate drives it.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class BridgeState: ObservableObject {

	// MARK: - Published UI state

	@Published var currentRoot: String?          // absolute path, or nil
	@Published var recents: [String] = []         // most-recent-first, max 5
	@Published var serverRunning = false
	@Published var sessionCount = 0
	@Published var docsExists = false             // does <root>/docs exist?
	@Published var skillInstalled = false
	@Published var lastLog = ""

	// Settings (persisted)
	@Published var port: UInt16 = 19850
	@Published var skillsDirectory = "~/.claude/skills"
	@Published var skillFolderName = "index-project"
	@Published var skillRepoURL = ""              // user fills this in
	@Published var autoStart = true

	// MARK: - Plumbing

	private let root = CurrentRoot()
	private var server: HTTPServer?
	private let maxRecents = 5

	private enum Key {
		static let currentRoot = "currentRoot"
		static let recents = "recentProjects"
		static let port = "serverPort"
		static let skillsDir = "skillsDirectory"
		static let skillFolder = "skillFolderName"
		static let skillRepo = "skillRepoURL"
		static let autoStart = "autoStartServer"
		static let launchedBefore = "hasLaunchedBefore"
	}

	var mcpURL: String { "http://127.0.0.1:\(port)/mcp" }

	var addCommand: String {
		"claude mcp add --transport http --scope local claude-bridge \(mcpURL)"
	}

	var isFirstLaunch: Bool {
		!UserDefaults.standard.bool(forKey: Key.launchedBefore)
	}

	// MARK: - Init

	init() {
		let d = UserDefaults.standard
		if let p = d.object(forKey: Key.port) as? Int, p > 0, p < 65536 { port = UInt16(p) }
		if let s = d.string(forKey: Key.skillsDir) { skillsDirectory = s }
		if let f = d.string(forKey: Key.skillFolder) { skillFolderName = f }
		if let r = d.string(forKey: Key.skillRepo) { skillRepoURL = r }
		if d.object(forKey: Key.autoStart) != nil { autoStart = d.bool(forKey: Key.autoStart) }
		recents = (d.array(forKey: Key.recents) as? [String]) ?? []

		buildServer()

		if let saved = d.string(forKey: Key.currentRoot),
			FileManager.default.fileExists(atPath: (saved as NSString).expandingTildeInPath) {
			applyRoot(saved, persist: false)
		}
		refreshSkillStatus()

		if autoStart { startServer() }
	}

	// MARK: - Server

	private func buildServer() {
		let handler = MCPHandler(currentRoot: root)
		let s = HTTPServer(port: port, handler: handler)
		s.onStateChanged = { [weak self] running in self?.serverRunning = running }
		s.onSessionsChanged = { [weak self] n in self?.sessionCount = n }
		s.onLog = { [weak self] msg in self?.lastLog = msg }
		server = s
	}

	func startServer() {
		guard let server = server, !serverRunning else { return }
		do {
			try server.start()
		} catch {
			lastLog = "Failed to start: \(error.localizedDescription)"
		}
	}

	func stopServer() {
		server?.stop()
	}

	/// Apply a new port: persist, rebuild the server, restart if it was running.
	func applyPort(_ newPort: UInt16) {
		guard newPort > 0 else { return }
		let wasRunning = serverRunning
		stopServer()
		port = newPort
		UserDefaults.standard.set(Int(newPort), forKey: Key.port)
		buildServer()
		if wasRunning { startServer() }
	}

	// MARK: - Project root

	/// Set the active project root (from the folder picker).
	func selectRoot(_ path: String) {
		applyRoot(path, persist: true)
	}

	private func applyRoot(_ path: String, persist: Bool) {
		let expanded = (path as NSString).expandingTildeInPath
		currentRoot = expanded
		root.set(expanded)               // server reads from here, live
		docsExists = FileManager.default.fileExists(
			atPath: URL(fileURLWithPath: expanded).appendingPathComponent("docs").path)

		// MRU: dedupe, prepend, cap.
		recents.removeAll { $0 == expanded }
		recents.insert(expanded, at: 0)
		if recents.count > maxRecents { recents = Array(recents.prefix(maxRecents)) }

		if persist {
			let d = UserDefaults.standard
			d.set(expanded, forKey: Key.currentRoot)
			d.set(recents, forKey: Key.recents)
		}
		refreshSkillStatus()
	}

	func clearRecents() {
		recents.removeAll()
		UserDefaults.standard.set(recents, forKey: Key.recents)
	}

	// MARK: - Skill

	private var installer: SkillInstaller {
		SkillInstaller(skillsDirectory: skillsDirectory, folderName: skillFolderName, repoURL: skillRepoURL)
	}

	func refreshSkillStatus() {
		skillInstalled = installer.isInstalled
	}

	/// Install/refresh the skill off the main thread; returns an error message or nil.
	func installSkill() async -> String? {
		let inst = installer
		let result: String? = await Task.detached {
			do {
				try inst.install()
				return nil
			} catch let e as BridgeError {
				return e.message
			} catch {
				return error.localizedDescription
			}
		}.value
		refreshSkillStatus()
		return result
	}

	// MARK: - Settings persistence

	func saveSkillSettings() {
		let d = UserDefaults.standard
		d.set(skillsDirectory, forKey: Key.skillsDir)
		d.set(skillFolderName, forKey: Key.skillFolder)
		d.set(skillRepoURL, forKey: Key.skillRepo)
		refreshSkillStatus()
	}

	func saveAutoStart() {
		UserDefaults.standard.set(autoStart, forKey: Key.autoStart)
	}

	func markLaunched() {
		UserDefaults.standard.set(true, forKey: Key.launchedBefore)
	}
}
