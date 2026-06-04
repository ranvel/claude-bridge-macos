//
//  AppDelegate.swift
//  ClaudeBridge
//
//  Owns the menu-bar status item and the popover that hosts BridgeView.
//  Also handles the optional standalone window, the folder picker, and
//  first-launch onboarding (offer to install the index-project skill).
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

	private let state = BridgeState()
	private var statusItem: NSStatusItem!
	private let popover = NSPopover()
	private var window: NSWindow?

	// MARK: - Lifecycle

	func applicationDidFinishLaunching(_ notification: Notification) {
		setUpStatusItem()
		setUpPopover()

		// First launch: show the popover so the app isn't "invisible", and
		// offer to install the skill if it's missing.
		if state.isFirstLaunch {
			DispatchQueue.main.async { [weak self] in
				self?.showPopover()
				self?.offerSkillInstallIfNeeded()
				self?.state.markLaunched()
			}
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		state.stopServer()
	}

	// MARK: - Status item

	private func setUpStatusItem() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		if let button = statusItem.button {
			// Prefer an SF Symbol; fall back to the bridge emoji if unavailable.
			if let image = NSImage(systemSymbolName: "bridge.fill", accessibilityDescription: "Claude Bridge") {
				image.isTemplate = true
				button.image = image
			} else {
				button.title = "🌉"
			}
			button.action = #selector(togglePopover(_:))
			button.target = self
		}
	}

	// MARK: - Popover

	private func setUpPopover() {
		popover.behavior = .transient
		popover.animates = true
		popover.contentSize = NSSize(width: 380, height: 560)
		popover.contentViewController = NSHostingController(rootView: makeView())
	}

	private func makeView() -> BridgeView {
		BridgeView(
			state: state,
			onChooseFolder: { [weak self] in self?.chooseFolder() },
			onOpenWindow: { [weak self] in self?.openWindow() },
			onQuit: { NSApp.terminate(nil) }
		)
	}

	@objc private func togglePopover(_ sender: Any?) {
		if popover.isShown {
			popover.performClose(sender)
		} else {
			showPopover()
		}
	}

	private func showPopover() {
		guard let button = statusItem.button else { return }
		popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
		// Bring the popover's window forward so text fields are focusable.
		popover.contentViewController?.view.window?.makeKey()
		NSApp.activate(ignoringOtherApps: true)
	}

	// MARK: - Standalone window

	private func openWindow() {
		popover.performClose(nil)

		if let window = window {
			window.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		let hosting = NSHostingController(rootView: makeView())
		let win = NSWindow(contentViewController: hosting)
		win.title = "Claude Bridge 🌉"
		win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
		win.setContentSize(NSSize(width: 380, height: 600))
		win.isReleasedWhenClosed = false
		win.center()
		window = win

		win.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	// MARK: - Folder picker

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseFiles = false
		panel.canChooseDirectories = true
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = false
		panel.prompt = "Use Project"
		panel.message = "Choose a project root for Claude Bridge."
		if let current = state.currentRoot {
			panel.directoryURL = URL(fileURLWithPath: current)
		}

		NSApp.activate(ignoringOtherApps: true)
		let response = panel.runModal()
		if response == .OK, let url = panel.url {
			state.selectRoot(url.path)
		}
	}

	// MARK: - First-launch onboarding

	private func offerSkillInstallIfNeeded() {
		guard !state.skillInstalled else { return }

		let alert = NSAlert()
		alert.messageText = "Install the index-project skill?"
		alert.informativeText = """
		Claude Bridge works best with the “index-project” skill, which teaches \
		Claude how to build and maintain a project-index.md map of your codebase.

		It installs from a public GitHub repo into \(state.skillsDirectory)/\(state.skillFolderName).

		You can set or change the repo URL anytime in Settings.
		"""
		alert.addButton(withTitle: "Install Now")
		alert.addButton(withTitle: "Later")
		alert.alertStyle = .informational

		let choice = alert.runModal()
		guard choice == .alertFirstButtonReturn else { return }

		if state.skillRepoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			// No URL configured yet — point the user at Settings via the popover.
			let needURL = NSAlert()
			needURL.messageText = "Set the skill repo URL first"
			needURL.informativeText = "Open Settings in the Claude Bridge popover, paste the GitHub URL for the index-project skill, then click Install."
			needURL.addButton(withTitle: "OK")
			needURL.runModal()
			showPopover()
			return
		}

		Task { @MainActor in
			let error = await state.installSkill()
			let result = NSAlert()
			if let error = error {
				result.messageText = "Skill install failed"
				result.informativeText = error
				result.alertStyle = .warning
			} else {
				result.messageText = "Skill installed ✅"
				result.informativeText = "The index-project skill is ready in \(state.skillsDirectory)/\(state.skillFolderName)."
				result.alertStyle = .informational
			}
			result.addButton(withTitle: "OK")
			result.runModal()
		}
	}
}
