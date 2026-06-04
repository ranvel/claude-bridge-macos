//
//  BridgeView.swift
//  ClaudeBridge
//
//  The menu-bar popover content (also usable as a standalone window).
//  Project picker + last-5 recents + server status + skill install + settings.
//

import SwiftUI
import AppKit

struct BridgeView: View {
	@ObservedObject var state: BridgeState

	let onChooseFolder: () -> Void
	let onOpenWindow: () -> Void
	let onQuit: () -> Void

	@State private var showSettings = false
	@State private var installing = false
	@State private var errorMessage: String?
	@State private var portText = ""

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 14) {
				header
				Divider()
				projectSection
				if !state.recents.isEmpty { recentsSection }
				Divider()
				skillSection
				Divider()
				settingsDisclosure
				footer
			}
			.padding(16)
		}
		.frame(width: 380)
		.frame(maxHeight: 640)
		.onAppear { portText = String(state.port) }
		.alert("Heads up", isPresented: Binding(
			get: { errorMessage != nil },
			set: { if !$0 { errorMessage = nil } }
		)) {
			Button("OK", role: .cancel) { errorMessage = nil }
		} message: {
			Text(errorMessage ?? "")
		}
	}

	// MARK: - Header / server status

	private var header: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Text("🌉 Claude Bridge").font(.headline)
				Spacer()
				Button(state.serverRunning ? "Stop" : "Start") {
					state.serverRunning ? state.stopServer() : state.startServer()
				}
			}
			HStack(spacing: 6) {
				Circle()
					.fill(state.serverRunning ? Color.green : Color.secondary)
					.frame(width: 8, height: 8)
				Text(state.serverRunning
					? "Listening on port \(state.port)"
					: "Stopped")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			if state.serverRunning {
				copyRow(label: "Endpoint", value: state.mcpURL)
			}
		}
	}

	// MARK: - Project

	private var projectSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Active project").font(.subheadline).bold()
			if let root = state.currentRoot {
				Text((root as NSString).abbreviatingWithTildeInPath)
					.font(.system(.caption, design: .monospaced))
					.lineLimit(2)
					.truncationMode(.middle)
					.textSelection(.enabled)
			} else {
				Text("No project selected")
					.font(.caption)
					.foregroundColor(.secondary)
			}
			Button("Choose Folder…", action: onChooseFolder)
		}
	}

	// MARK: - Recents

	private var recentsSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text("Recent projects").font(.subheadline).bold()
				Spacer()
				Button {
					state.clearRecents()
				} label: {
					Image(systemName: "trash").font(.caption)
				}
				.buttonStyle(.borderless)
				.help("Clear recent projects")
			}
			ForEach(state.recents, id: \.self) { path in
				Button {
					if state.selectRoot(path) {
						Self.showDocsConsentAlert()
					}
				} label: {
					HStack(spacing: 8) {
						Image(systemName: path == state.currentRoot ? "largecircle.fill.circle" : "circle")
							.font(.caption)
							.foregroundColor(path == state.currentRoot ? .accentColor : .secondary)
						VStack(alignment: .leading, spacing: 1) {
							Text(URL(fileURLWithPath: path).lastPathComponent)
								.font(.caption).bold()
							Text((path as NSString).abbreviatingWithTildeInPath)
								.font(.system(size: 10, design: .monospaced))
								.foregroundColor(.secondary)
								.lineLimit(1)
								.truncationMode(.middle)
						}
						Spacer()
					}
					.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
		}
	}

	// MARK: - Skill

	private var skillSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(state.skillInstalled ? "✅ index-project skill" : "⚠️ index-project skill")
					.font(.subheadline).bold()
				Spacer()
			}
			Text(state.skillInstalled
				? "Installed in \(state.skillsDirectory)/\(state.skillFolderName)"
				: "Not installed. Claude can maintain a project-index.md with this skill.")
				.font(.caption)
				.foregroundColor(.secondary)
			if !state.skillInstalled {
				Button {
					installSkill()
				} label: {
					HStack(spacing: 6) {
						if installing { ProgressView().controlSize(.small) }
						Text(installing ? "Installing…" : "Install skill from GitHub")
					}
				}
				.disabled(installing)
			}
		}
	}

	private func installSkill() {
		if state.skillRepoURL.trimmingCharacters(in: .whitespaces).isEmpty {
			showSettings = true
			errorMessage = "Set a skill repo URL in Settings first (e.g. your GitHub repo for the index-project skill)."
			return
		}
		installing = true
		Task {
			let err = await state.installSkill()
			installing = false
			if let err { errorMessage = err }
		}
	}

	// MARK: - Settings

	private var settingsDisclosure: some View {
		DisclosureGroup("Settings", isExpanded: $showSettings) {
			VStack(alignment: .leading, spacing: 10) {
				labeledField("Port") {
					HStack {
						TextField("19850", text: $portText)
							.textFieldStyle(.roundedBorder)
							.frame(width: 90)
						Button("Apply") {
							if let p = UInt16(portText.trimmingCharacters(in: .whitespaces)) {
								state.applyPort(p)
							}
						}
					}
				}
				labeledField("Skills directory") {
					TextField("~/.claude/skills", text: $state.skillsDirectory)
						.textFieldStyle(.roundedBorder)
						.onSubmit { state.saveSkillSettings() }
				}
				labeledField("Skill folder name") {
					TextField("index-project", text: $state.skillFolderName)
						.textFieldStyle(.roundedBorder)
						.onSubmit { state.saveSkillSettings() }
				}
				labeledField("Skill repo URL") {
					TextField(BridgeState.defaultSkillRepoURL, text: $state.skillRepoURL)
						.textFieldStyle(.roundedBorder)
						.onSubmit { state.saveSkillSettings() }
				}
				Toggle("Start server on launch", isOn: $state.autoStart)
					.onChange(of: state.autoStart) { _ in state.saveAutoStart() }
				Button("Save skill settings") { state.saveSkillSettings() }
					.font(.caption)
			}
			.padding(.top, 8)
		}
		.font(.subheadline.bold())
	}

	private var footer: some View {
		HStack {
			Button("Open in Window", action: onOpenWindow)
			Spacer()
			Button("Quit", action: onQuit)
		}
		.font(.caption)
	}

	// MARK: - Small helpers

	private func copyRow(label: String, value: String) -> some View {
		HStack(spacing: 6) {
			Text(value)
				.font(.system(size: 10, design: .monospaced))
				.lineLimit(1)
				.truncationMode(.middle)
				.textSelection(.enabled)
			Spacer()
			Button {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(value, forType: .string)
			} label: {
				Image(systemName: "doc.on.doc").font(.caption)
			}
			.buttonStyle(.borderless)
			.help("Copy \(label)")
		}
		.padding(6)
		.background(Color.secondary.opacity(0.1))
		.cornerRadius(6)
	}

	private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(label).font(.caption).foregroundColor(.secondary)
			content()
		}
	}

	static func showDocsConsentAlert() {
		let alert = NSAlert()
		alert.messageText = "docs/ folder access"
		alert.informativeText = "Claude can read, create, overwrite, update, and delete files in this project's docs/ folder."
		alert.addButton(withTitle: "OK")
		alert.alertStyle = .informational
		alert.runModal()
	}
}
