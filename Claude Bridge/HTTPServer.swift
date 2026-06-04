//
//  HTTPServer.swift
//  ClaudeBridge
//
//  A tiny, dependency-free HTTP/1.1 server on Network.framework that
//  speaks the MCP HTTP+SSE transport:
//
//    GET  /sse                      -> opens an SSE stream; first event is
//                                      `endpoint` carrying the POST URL.
//    POST /messages?sessionId=<id>  -> JSON-RPC in; 202 Accepted out; the
//                                      JSON-RPC response is delivered over
//                                      the matching SSE stream.
//    GET  /health                   -> liveness check.
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
	private var sessions: [String: SSESession] = [:]

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
			for s in self.sessions.values { s.close() }
			self.sessions.removeAll()
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
		switch (req.method, req.path) {

		case ("GET", "/sse"):
			let sid = UUID().uuidString
			let session = SSESession(id: sid, connection: conn, queue: queue)
			sessions[sid] = session
			emitSessions(sessions.count)
			log("SSE session opened: \(sid)")

			// Reclaim the session when this connection dies.
			conn.stateUpdateHandler = { [weak self] state in
				switch state {
				case .failed, .cancelled:
					self?.queue.async { self?.removeSession(sid) }
				default:
					break
				}
			}
			session.sendHandshake()

		case ("POST", "/messages"):
			guard let sid = req.query["sessionId"], let session = sessions[sid] else {
				respond(conn, status: "404 Not Found", body: "no such session")
				return
			}
			handlePost(body: body, session: session)
			respond(conn, status: "202 Accepted", body: "")

		case ("GET", "/health"):
			respond(conn, status: "200 OK", body: "claude-bridge ok")

		case ("OPTIONS", _):
			let head = "HTTP/1.1 204 No Content\r\n"
				+ "Access-Control-Allow-Origin: *\r\n"
				+ "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
				+ "Access-Control-Allow-Headers: *\r\n"
				+ "Content-Length: 0\r\nConnection: close\r\n\r\n"
			sendRaw(conn, Data(head.utf8), thenClose: true)

		default:
			respond(conn, status: "404 Not Found", body: "not found")
		}
	}

	private func handlePost(body: Data, session: SSESession) {
		guard let obj = try? JSONSerialization.jsonObject(with: body) else { return }

		// A single message, or a JSON-RPC batch.
		if let single = obj as? [String: Any] {
			deliver(handler.handle(single), to: session)
		} else if let batch = obj as? [[String: Any]] {
			for msg in batch { deliver(handler.handle(msg), to: session) }
		}
	}

	private func deliver(_ response: [String: Any]?, to session: SSESession) {
		guard let response = response else { return }   // notification: no reply
		guard let data = try? JSONSerialization.data(withJSONObject: response),
			let str = String(data: data, encoding: .utf8) else { return }
		session.send(event: "message", data: str)
	}

	private func removeSession(_ id: String) {
		if let s = sessions.removeValue(forKey: id) {
			s.close()
			log("SSE session closed: \(id)")
			emitSessions(sessions.count)
		}
	}

	// MARK: - HTTP responses

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

	// MARK: - Loopback gate

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

// MARK: - SSE session

/// One open `text/event-stream` connection plus a keepalive heartbeat.
final class SSESession {
	let id: String
	private let connection: NWConnection
	private let queue: DispatchQueue
	private var keepalive: DispatchSourceTimer?

	init(id: String, connection: NWConnection, queue: DispatchQueue) {
		self.id = id
		self.connection = connection
		self.queue = queue
	}

	func sendHandshake() {
		let head = "HTTP/1.1 200 OK\r\n"
			+ "Content-Type: text/event-stream\r\n"
			+ "Cache-Control: no-cache\r\n"
			+ "Connection: keep-alive\r\n"
			+ "Access-Control-Allow-Origin: *\r\n\r\n"
		rawSend(Data(head.utf8))
		// Tell the client where to POST its JSON-RPC requests.
		send(event: "endpoint", data: "/messages?sessionId=\(id)")
		startKeepalive()
	}

	func send(event: String, data: String) {
		// Our payloads are single-line (compact JSON), so one data: line is fine.
		let frame = "event: \(event)\ndata: \(data)\n\n"
		rawSend(Data(frame.utf8))
	}

	private func startKeepalive() {
		let t = DispatchSource.makeTimerSource(queue: queue)
		t.schedule(deadline: .now() + 15, repeating: 15)
		t.setEventHandler { [weak self] in
			self?.rawSend(Data(": keepalive\n\n".utf8))
		}
		t.resume()
		keepalive = t
	}

	private func rawSend(_ data: Data) {
		connection.send(content: data, completion: .contentProcessed { _ in })
	}

	func close() {
		keepalive?.cancel()
		keepalive = nil
		connection.cancel()
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
