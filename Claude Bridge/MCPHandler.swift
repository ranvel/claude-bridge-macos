//
//  MCPHandler.swift
//  ClaudeBridge
//
//  JSON-RPC 2.0 dispatch for the MCP methods we support:
//  initialize, notifications/initialized, ping, tools/list, tools/call.
//

import Foundation

struct MCPHandler {
	let currentRoot: CurrentRoot
	let serverVersion = "1.0.0"
	let protocolVersion = "2024-11-05"

	/// Handle one JSON-RPC message. Returns the response object to send back,
	/// or nil for notifications (which get no response).
	func handle(_ message: [String: Any]) -> [String: Any]? {
		let method = message["method"] as? String ?? ""
		let id = message["id"]                       // may be Int, String, or nil
		let params = message["params"] as? [String: Any] ?? [:]

		// Notifications carry no id and expect no reply.
		let isNotification = (id == nil)

		switch method {
		case "initialize":
			return ok(id, [
				"protocolVersion": protocolVersion,
				"capabilities": ["tools": [String: Any]()],
				"serverInfo": ["name": "claude-bridge", "version": serverVersion],
			])

		case "notifications/initialized", "notifications/cancelled":
			return nil

		case "ping":
			return ok(id, [String: Any]())

		case "tools/list":
			return ok(id, ["tools": Tools.definitions()])

		case "tools/call":
			let result = callTool(params)
			return ok(id, result)

		default:
			if isNotification { return nil }
			return err(id, code: -32601, message: "Method not found: \(method)")
		}
	}

	// MARK: - tools/call

	private func callTool(_ params: [String: Any]) -> [String: Any] {
		let name = params["name"] as? String ?? ""
		let arguments = params["arguments"] as? [String: Any] ?? [:]

		guard let rootPath = currentRoot.get() else {
			return [
				"content": [["type": "text", "text": "❌ No project root selected. Pick one in the Claude Bridge menu-bar app."]],
				"isError": true,
			]
		}

		let result = Tools(rootPath: rootPath).call(name: name, arguments: arguments)
		return [
			"content": result.blocks.map { ["type": "text", "text": $0] },
			"isError": result.isError,
		]
	}

	// MARK: - Envelopes

	private func ok(_ id: Any?, _ result: [String: Any]) -> [String: Any] {
		var resp: [String: Any] = ["jsonrpc": "2.0", "result": result]
		resp["id"] = id ?? NSNull()
		return resp
	}

	private func err(_ id: Any?, code: Int, message: String) -> [String: Any] {
		var resp: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
		resp["id"] = id ?? NSNull()
		return resp
	}
}
