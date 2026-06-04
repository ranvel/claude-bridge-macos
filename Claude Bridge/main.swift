//
//  main.swift
//  ClaudeBridge
//
//  Menu-bar resident MCP server. Bootstraps NSApplication as an
//  .accessory app (no Dock icon) and hands off to AppDelegate.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory => lives in the menu bar, no Dock icon, no main menu bar.
app.setActivationPolicy(.accessory)
app.run()
