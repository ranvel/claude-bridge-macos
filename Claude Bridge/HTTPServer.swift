//
//  HTTPServer.swift
//  ClaudeBridge
//
//  A dependency-free HTTP/1.1 server on Network.framework implementing
//  the MCP Streamable HTTP transport (2025-06-18):
//
//    POST   /mcp     -> JSON-RPC in; 200+JSON or 202 Accepted out.
//                       No SSE upgrade — all tools are single-request/
//                       single-response, so we never stream.
//    GET    /mcp     -> 405 (no server-initiated streams).
//    DELETE /mcp     -> terminate session, 204.
//    GET    /health  -> liveness check.
//
//  Loopback only: non-local peers are rejected on accept.
//

import Foundation
import Network

final class HTTPServer {
	let port: UInt16
	private let handler: MCPHandler
	private let queue = DispatchQueue(label: "surf.ranvel.ClaudeBridge.http")

	private var listener: NWListener?

	// Active MCP sessions (minted at initialize, removed on DELETE or server stop).
	// Session count may drift upward if clients disconnect without sending DELETE —
	// this is a known limitation of in-memory sessions with no idle TTL. Treat the
	// count as a soft "has anything connected" indicator, not a precise gauge.
	private var activeSessions: Set<String> = []

	/// Max POST body we'll buffer (16 MB).
	private let maxBody = 16 * 1024 * 1024

	// Callbacks (always delivered on the main thread).
	var onStateChanged: ((Bool) -> Void)?
	var onSessionsChanged: ((Int) -> Void)?
	var onLog: ((String) -> Void)?

	private(set) var isRunning = false

	init(port: UInt16, handler: MCPHandler) {
		self.port = port
		self.handler = handler
	}

	// MARK: - Lifecycle

	func start() throws {
		let params = NWParameters.tcp
		params.allowLocalEndpointReuse = true

		let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
		listener.newConnectionHandler = { [weak self] conn in
			self?.handleNewConnection(conn)
		}
		listener.stateUpdateHandler = { [weak self] state in
			guard let self = self else { return }
			switch state {
			case .ready:
				self.isRunning = true
				self.emitState(true)
				self.log("listening on 127.0.0.1:\(self.port)")
			case .failed(let e):
				self.isRunning = false
				self.emitState(false)
				self.log("listener failed: \(e)")
			case .cancelled:
				self.isRunning = false
				self.emitState(false)
			default:
				break
			}
		}
		self.listener = listener
		listener.start(queue: queue)
	}

	func stop() {
		queue.async {
			self.listener?.cancel()
			self.listener = nil
			self.activeSessions.removeAll()
			self.emitSessions(0)
			self.isRunning = false
			self.emitState(false)
		}
	}

	// MARK: - Connection handling

	private func handleNewConnection(_ conn: NWConnection) {
		conn.stateUpdateHandler = { [weak self] state in
			guard let self = self else { return }
			switch state {
			case .ready:
				guard self.isLoopback(conn) else {
					self.log("rejected non-loopback peer")
					conn.cancel()
					return
				}
				self.receiveRequest(on: conn, buffer: Data())
			case .failed, .cancelled:
				break
			default:
				break
			}
		}
		conn.start(queue: queue)
	}

	private func receiveRequest(on conn: NWConnection, buffer: Data) {
		conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
			guard let self = self else { return }

			if error != nil { conn.cancel(); return }

			var buf = buffer
			if let d = data, !d.isEmpty { buf.append(d) }

			guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
				if isComplete { conn.cancel(); return }
				self.receiveRequest(on: conn, buffer: buf)
				return
			}

			let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
			guard let req = HTTPRequest(headerData: headerData) else {
				self.respond(conn, status: "400 Bad Request", body: "bad request")
				return
			}

			let contentLength = Int(req.headers["content-length"] ?? "0") ?? 0
			if contentLength > self.maxBody {
				self.respond(conn, status: "413 Payload Too Large", body: "body too large")
				return
			}

			let bodyStart = headerEnd.upperBound
			let bodyAvailable = buf.count - bodyStart
			if bodyAvailable < contentLength {
				if isComplete { conn.cancel(); return }
				self.receiveRequest(on: conn, buffer: buf)
				return
			}

			let body = contentLength > 0
				? buf.subdata(in: bodyStart..<(bodyStart + contentLength))
				: Data()
			self.dispatch(req, body: body, conn: conn)
		}
	}

	// MARK: - Routing

	private func dispatch(_ req: HTTPRequest, body: Data, conn: NWConnection) {
		// Origin validation: reject non-local origins to block DNS-rebinding.
		// Native HTTP clients (like Claude Code) typically omit Origin entirely,
		// so absent = allowed; only browser-initiated requests carry Origin.
		if let origin = req.headers["origin"], !isLocalOrigin(origin) {
			respond(conn, status: "403 Forbidden", body: "non-local origin rejected")
			return
		}

		switch (req.method, req.path) {

		case ("POST", "/mcp"):
			handleMCPPost(req, body: body, conn: conn)

		case ("GET", "/mcp"):
			respond(conn, status: "405 Method Not Allowed", body: "server does not support GET streaming")

		case ("DELETE", "/mcp"):
			handleMCPDelete(req, conn: conn)

		case ("GET", "/health"):
			respond(conn, status: "200 OK", body: "claude-bridge ok")

		case ("OPTIONS", _):
			let head = "HTTP/1.1 204 No Content\r\n"
				+ "Access-Control-Allow-Origin: *\r\n"
				+ "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
				+ "Access-Control-Allow-Headers: *\r\n"
				+ "Content-Length: 0\r\nConnection: close\r\n\r\n"
			sendRaw(conn, Data(head.utf8), thenClose: true)

		default:
			respond(conn, status: "404 Not Found", body: "not found")
		}
	}

	// MARK: - MCP Streamable HTTP

	private func handleMCPPost(_ req: HTTPRequest, body: Data, conn: NWConnection) {
		guard let ct = req.headers["content-type"], ct.hasPrefix("application/json") else {
			respond(conn, status: "415 Unsupported Media Type", body: "expected Content-Type: application/json")
			return
		}

		// Single JSON-RPC object only — batching was removed in the 2025-06-18 spec.
		guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
			respond(conn, status: "400 Bad Request", body: "invalid JSON or unexpected array")
			return
		}

		let method = obj["method"] as? String ?? ""

		if method == "initialize" {
			// initialize is the only request that skips session validation — it's
			// how the client obtains a session ID in the first place. The routing
			// layer mints the UUID here to keep MCPHandler session-ignorant.
			let sessionId = UUID().uuidString
			activeSessions.insert(sessionId)
			emitSessions(activeSessions.count)
			log("session initialized: \(sessionId)")

			let result = handler.handle(obj)
			respondJSON(conn, result: result, sessionId: sessionId)
		} else {
			// Leniency policy (single-user loopback server):
			//
			// - Missing Mcp-Session-Id: accepted (no 400). The spec says a server
			//   that requires sessions SHOULD return 400, but for loopback this
			//   avoids breaking minimal or odd clients.
			// - Present but unknown/stale Mcp-Session-Id: 404, so the client knows
			//   to reinitialize. An app restart invalidates all in-memory sessions;
			//   the first post-restart request gets a 404, and the client's
			//   spec-blessed recovery path is to reinitialize.
			// - MCP-Protocol-Version header: accepted and ignored. The 2025-06-18
			//   spec made this mandatory on post-init requests. If absent, the spec
			//   says to default to 2025-03-26. We don't vary behavior by version,
			//   so the value is irrelevant either way.
			if let clientSession = req.headers["mcp-session-id"] {
				guard activeSessions.contains(clientSession) else {
					respond(conn, status: "404 Not Found", body: "unknown or stale session — reinitialize")
					return
				}
			}

			let result = handler.handle(obj)
			respondJSON(conn, result: result, sessionId: req.headers["mcp-session-id"])
		}
	}

	private func handleMCPDelete(_ req: HTTPRequest, conn: NWConnection) {
		guard let sessionId = req.headers["mcp-session-id"],
			  activeSessions.remove(sessionId) != nil else {
			respond(conn, status: "404 Not Found", body: "unknown session")
			return
		}
		emitSessions(activeSessions.count)
		log("session terminated: \(sessionId)")

		let head = "HTTP/1.1 204 No Content\r\n"
			+ "Access-Control-Allow-Origin: *\r\n"
			+ "Connection: close\r\n\r\n"
		sendRaw(conn, Data(head.utf8), thenClose: true)
	}

	// MARK: - HTTP responses

	private func respondJSON(_ conn: NWConnection, result: [String: Any]?, sessionId: String?) {
		if let result = result {
			guard let data = try? JSONSerialization.data(withJSONObject: result) else {
				respond(conn, status: "500 Internal Server Error", body: "failed to serialize response")
				return
			}
			var head = "HTTP/1.1 200 OK\r\n"
				+ "Content-Type: application/json\r\n"
				+ "Content-Length: \(data.count)\r\n"
				+ "Access-Control-Allow-Origin: *\r\n"
			if let sid = sessionId {
				head += "Mcp-Session-Id: \(sid)\r\n"
			}
			head += "Connection: close\r\n\r\n"
			sendRaw(conn, Data(head.utf8) + data, thenClose: true)
		} else {
			var head = "HTTP/1.1 202 Accepted\r\n"
				+ "Access-Control-Allow-Origin: *\r\n"
			if let sid = sessionId {
				head += "Mcp-Session-Id: \(sid)\r\n"
			}
			head += "Content-Length: 0\r\nConnection: close\r\n\r\n"
			sendRaw(conn, Data(head.utf8), thenClose: true)
		}
	}

	private func respond(_ conn: NWConnection, status: String, body: String) {
		let bodyData = Data(body.utf8)
		let head = "HTTP/1.1 \(status)\r\n"
			+ "Content-Type: text/plain; charset=utf-8\r\n"
			+ "Content-Length: \(bodyData.count)\r\n"
			+ "Access-Control-Allow-Origin: *\r\n"
			+ "Connection: close\r\n\r\n"
		sendRaw(conn, Data(head.utf8) + bodyData, thenClose: true)
	}

	private func sendRaw(_ conn: NWConnection, _ data: Data, thenClose: Bool) {
		conn.send(content: data, completion: .contentProcessed { _ in
			if thenClose { conn.cancel() }
		})
	}

	// MARK: - Validation helpers

	private func isLoopback(_ conn: NWConnection) -> Bool {
		guard let remote = conn.currentPath?.remoteEndpoint else { return true }
		if case let .hostPort(host, _) = remote {
			switch host {
			case .ipv4(let a): return a.isLoopback
			case .ipv6(let a): return a.isLoopback
			case .name(let n, _): return n == "localhost"
			@unknown default: return false
			}
		}
		return true
	}

	private func isLocalOrigin(_ origin: String) -> Bool {
		let lower = origin.lowercased()
		if lower == "null" { return true }
		let stripped = lower
			.replacingOccurrences(of: "https://", with: "")
			.replacingOccurrences(of: "http://", with: "")
			.split(separator: ":").first.map(String.init) ?? lower
		return stripped == "localhost" || stripped == "127.0.0.1" || stripped == "[::1]"
	}

	// MARK: - Main-thread emitters

	private func emitState(_ running: Bool) {
		DispatchQueue.main.async { self.onStateChanged?(running) }
	}

	private func emitSessions(_ count: Int) {
		DispatchQueue.main.async { self.onSessionsChanged?(count) }
	}

	private func log(_ msg: String) {
		DispatchQueue.main.async { self.onLog?(msg) }
	}
}

// MARK: - Minimal HTTP request parser

struct HTTPRequest {
	let method: String
	let path: String
	let query: [String: String]
	let headers: [String: String]   // keys lowercased

	init?(headerData: Data) {
		guard let text = String(data: headerData, encoding: .utf8) else { return nil }
		let lines = text.components(separatedBy: "\r\n")
		guard let requestLine = lines.first else { return nil }

		let parts = requestLine.split(separator: " ")
		guard parts.count >= 2 else { return nil }
		method = String(parts[0])

		let target = String(parts[1])
		if let q = target.firstIndex(of: "?") {
			path = String(target[..<q])
			query = HTTPRequest.parseQuery(String(target[target.index(after: q)...]))
		} else {
			path = target
			query = [:]
		}

		var hdrs: [String: String] = [:]
		for line in lines.dropFirst() where !line.isEmpty {
			guard let colon = line.firstIndex(of: ":") else { continue }
			let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
			let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			hdrs[key] = val
		}
		headers = hdrs
	}

	private static func parseQuery(_ qs: String) -> [String: String] {
		var out: [String: String] = [:]
		for pair in qs.split(separator: "&") {
			let kv = pair.split(separator: "=", maxSplits: 1)
			let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
			let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
			out[key] = value
		}
		return out
	}
}
