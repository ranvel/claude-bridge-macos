//
//  Tools.swift
//  ClaudeBridge
//
//  Thread-safe project-root holder + the nine Claude Bridge tools,
//  ported faithfully from server.py (same names, schemas, and output
//  formatting — emoji and all).
//

import Foundation

/// Thread-safe holder for the active project root. The UI (main thread)
/// writes it; the server queue reads it. A simple lock keeps the server
/// code synchronous inside Network.framework callbacks.
final class CurrentRoot {
	private let lock = NSLock()
	private var _path: String?

	func get() -> String? {
		lock.lock(); defer { lock.unlock() }
		return _path
	}

	func set(_ path: String?) {
		lock.lock(); _path = path; lock.unlock()
	}
}

/// Result of a tool call: one or more text blocks + an error flag.
struct ToolResult {
	var blocks: [String]
	var isError: Bool
	init(_ text: String, isError: Bool = false) {
		self.blocks = [text]
		self.isError = isError
	}
}

struct Tools {
	let root: URL
	private var docsDir: URL { root.appendingPathComponent("docs", isDirectory: true) }
	private var projectIndex: URL { root.appendingPathComponent("project-index.md") }

	init(rootPath: String) {
		self.root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
	}

	// MARK: - Tool schema (advertised via tools/list)

	static func definitions() -> [[String: Any]] {
		return [
			[
				"name": "list_docs",
				"description": "List all documents in the docs/ folder with last-modified timestamps. Returns a flat listing of all .md files.",
				"inputSchema": ["type": "object", "properties": [String: Any]()],
			],
			[
				"name": "read_doc",
				"description": "Read a document from docs/ by name. Case-sensitive. You can omit the .md extension. Examples: 'marketing', 'branding/colors.md'. Supports ranged reads via offset/limit for large documents.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"name": ["type": "string", "description": "Document name or path relative to docs/"],
						"offset": ["type": "integer", "description": "1-based line number to start reading from (default: 1)"],
						"limit": ["type": "integer", "description": "Maximum number of lines to return (default: whole file)"],
					],
					"required": ["name"],
				],
			],
			[
				"name": "write_doc",
				"description": "Create a new document in docs/. Fails if the document already exists — use update_doc to modify it, or delete_doc + write_doc to replace it entirely. Subdirectories are created automatically. If no extension is given, .md is appended.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"name": ["type": "string", "description": "Document name or path relative to docs/"],
						"content": ["type": "string", "description": "Full document content"],
					],
					"required": ["name", "content"],
				],
			],
			[
				"name": "update_doc",
				"description": "Update an existing document in docs/. Either pass a single old_text/new_text pair, or pass edits (an array of {old_text, new_text}) to apply several replacements in one call. Edits apply in array order, each against the result of the previous — an earlier edit can change whether a later old_text still matches. All edits are validated before anything is written: every old_text must match exactly once (case-sensitive) or the whole batch is rejected and the document is left untouched.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"name": ["type": "string", "description": "Document name or path relative to docs/"],
						"old_text": ["type": "string", "description": "Exact text to find (must appear exactly once). Use with new_text; mutually exclusive with edits."],
						"new_text": ["type": "string", "description": "Replacement text. Use with old_text; mutually exclusive with edits."],
						"edits": [
							"type": "array",
							"description": "Batch of edits, applied sequentially. Mutually exclusive with old_text/new_text.",
							"items": [
								"type": "object",
								"properties": [
									"old_text": ["type": "string", "description": "Exact text to find (must appear exactly once at its turn in the sequence)"],
									"new_text": ["type": "string", "description": "Replacement text"],
								],
								"required": ["old_text", "new_text"],
							],
						],
					],
					"required": ["name"],
				],
			],
			[
				"name": "delete_doc",
				"description": "Delete a document from docs/. Case-sensitive.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"name": ["type": "string", "description": "Document name or path relative to docs/"],
					],
					"required": ["name"],
				],
			],
			[
				"name": "read_file",
				"description": "Read any file from the project (read-only). Path is relative to project root. Case-sensitive. Supports ranged reads via offset/limit — required for files over the size cap. Binary files return metadata (type, size, mtime) instead of content.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"path": ["type": "string", "description": "File path relative to project root"],
						"offset": ["type": "integer", "description": "1-based line number to start reading from (default: 1)"],
						"limit": ["type": "integer", "description": "Maximum number of lines to return (default: whole file)"],
					],
					"required": ["path"],
				],
			],
			[
				"name": "list_directory",
				"description": "List contents of a project directory. Skips .git, node_modules, build artifacts, etc. Path is relative to project root (empty string = root).",
				"inputSchema": [
					"type": "object",
					"properties": [
						"path": ["type": "string", "description": "Directory path relative to project root", "default": ""],
						"depth": ["type": "integer", "description": "Max depth to recurse (1 = immediate children only)", "default": 1],
					],
				],
			],
			[
				"name": "search_files",
				"description": "Search for a pattern across project files (like grep). Returns matching lines with file paths and line numbers. Binary file content is not searched, but binary filenames are matched against the pattern (reported as name matches), and a footer reports how much binary content was skipped.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"pattern": ["type": "string", "description": "Search pattern (regex supported)"],
						"path": ["type": "string", "description": "File or directory to search in (relative to project root, empty = all)", "default": ""],
						"case_sensitive": ["type": "boolean", "description": "Whether search is case-sensitive (default: true)", "default": true],
					],
					"required": ["pattern"],
				],
			],
			[
				"name": "get_project_index",
				"description": "Read the project-index.md file from the project root. This is the master map of all project files.",
				"inputSchema": ["type": "object", "properties": [String: Any]()],
			],
		]
	}

	// MARK: - Dispatch

	func call(name: String, arguments: [String: Any]) -> ToolResult {
		do {
			switch name {
			case "list_docs": return try listDocs()
			case "read_doc": return try readDoc(arguments)
			case "write_doc": return try writeDoc(arguments)
			case "update_doc": return try updateDoc(arguments)
			case "delete_doc": return try deleteDoc(arguments)
			case "read_file": return try readFile(arguments)
			case "list_directory": return try listDirectory(arguments)
			case "search_files": return try searchFiles(arguments)
			case "get_project_index": return try getProjectIndex()
			default:
				return ToolResult("❌ Unknown tool: \(name)", isError: true)
			}
		} catch let e as BridgeError {
			return ToolResult("❌ \(e.message)", isError: true)
		} catch {
			return ToolResult("❌ Error: \(error.localizedDescription)", isError: true)
		}
	}

	// MARK: - docs/ tools

	private func listDocs() throws -> ToolResult {
		let fm = FileManager.default
		guard fm.fileExists(atPath: docsDir.path) else {
			return ToolResult("docs/ directory does not exist yet.")
		}

		var entries: [(String, String)] = []
		if let en = fm.enumerator(at: docsDir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) {
			for case let url as URL in en {
				if url.pathComponents.contains(where: { Skip.dirs.contains($0) }) { continue }
				let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
				guard vals?.isRegularFile == true else { continue }
				let rel = PathSafety.relativePath(of: url, under: docsDir)
				let sizeKB = Double(vals?.fileSize ?? 0) / 1024.0
				let mtime = Self.utcStamp(vals?.contentModificationDate ?? Date())
				entries.append((rel, String(format: "  %@  (%.1f KB, modified %@)", rel, sizeKB, mtime)))
			}
		}

		if entries.isEmpty {
			return ToolResult("docs/ is empty.")
		}
		entries.sort { $0.0 < $1.0 }
		let header = "📂 docs/ — \(entries.count) file(s):\n"
		return ToolResult(header + entries.map { $0.1 }.joined(separator: "\n"))
	}

	private func readDoc(_ args: [String: Any]) throws -> ToolResult {
		let name = try string(args, "name")
		let path = try PathSafety.resolveDocName(docsDir: docsDir, name: name)
		let fm = FileManager.default
		guard fm.fileExists(atPath: path.path) else {
			return ToolResult("❌ Document not found: \(name)\nUse list_docs to see available documents.", isError: true)
		}
		let rel = PathSafety.relativePath(of: path, under: docsDir)
		return try textFileResult(path: path, display: "docs/\(rel)", range: readRange(args))
	}

	private func writeDoc(_ args: [String: Any]) throws -> ToolResult {
		let name = try string(args, "name")
		let content = try string(args, "content")
		let path = try PathSafety.resolveDocName(docsDir: docsDir, name: name)
		let fm = FileManager.default

		try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
		let rel = PathSafety.relativePath(of: path, under: docsDir)
		if fm.fileExists(atPath: path.path) {
			return ToolResult("❌ docs/\(rel) already exists. Use update_doc to modify it, or delete_doc first to replace it.", isError: true)
		}
		try content.data(using: .utf8)?.write(to: path)
		return ToolResult("✅ Created docs/\(rel) (\(content.unicodeScalars.count) chars)")
	}

	private func updateDoc(_ args: [String: Any]) throws -> ToolResult {
		let name = try string(args, "name")
		let path = try PathSafety.resolveDocName(docsDir: docsDir, name: name)
		let fm = FileManager.default
		guard fm.fileExists(atPath: path.path) else {
			return ToolResult("❌ Document not found: \(name)", isError: true)
		}

		let content = try String(contentsOf: path, encoding: .utf8)
		let rel = PathSafety.relativePath(of: path, under: docsDir)

		// Exactly one of (old_text+new_text) or edits.
		let editsArg = args["edits"] as? [[String: Any]]
		let hasSinglePair = args["old_text"] != nil || args["new_text"] != nil
		if editsArg != nil && hasSinglePair {
			return ToolResult("❌ Provide either old_text/new_text or edits, not both.", isError: true)
		}

		var edits: [(old: String, new: String)] = []
		let isBatch = editsArg != nil
		if let editsArg {
			guard !editsArg.isEmpty else {
				return ToolResult("❌ edits must contain at least one edit.", isError: true)
			}
			for (i, e) in editsArg.enumerated() {
				guard let old = e["old_text"] as? String, let new = e["new_text"] as? String else {
					return ToolResult("❌ edit \(i + 1) of \(editsArg.count): each edit needs old_text and new_text strings.", isError: true)
				}
				edits.append((old, new))
			}
		} else {
			// Single-pair path: same required-argument errors as before.
			edits.append((try string(args, "old_text"), try string(args, "new_text")))
		}

		// Validate and apply sequentially against an in-memory copy — each edit
		// sees the result of the previous. Nothing touches disk unless every
		// edit matches exactly once.
		var working = content
		for (i, edit) in edits.enumerated() {
			let count = Self.occurrences(of: edit.old, in: working)
			let label = isBatch ? "edit \(i + 1) of \(edits.count): old_text" : "old_text"
			let suffix = isBatch ? " No changes applied." : ""
			if count == 0 {
				return ToolResult("❌ \(label) not found in docs/\(rel)\(isBatch ? "." : "")\(suffix)", isError: true)
			}
			if count > 1 {
				return ToolResult("❌ \(label) appears \(count) times (must be unique). Add more context to disambiguate.\(suffix)", isError: true)
			}
			guard let range = working.range(of: edit.old) else {
				return ToolResult("❌ \(label) not found in docs/\(rel)\(isBatch ? "." : "")\(suffix)", isError: true)
			}
			working = working.replacingCharacters(in: range, with: edit.new)
		}
		try working.data(using: .utf8)?.write(to: path)

		if !isBatch {
			let e = edits[0]
			return ToolResult("✅ Updated docs/\(rel) (replaced \(e.old.unicodeScalars.count) chars → \(e.new.unicodeScalars.count) chars)")
		}
		var lines = ["✅ Updated docs/\(rel) (\(edits.count) edits)"]
		var totalOld = 0, totalNew = 0
		for (i, e) in edits.enumerated() {
			let o = e.old.unicodeScalars.count, n = e.new.unicodeScalars.count
			totalOld += o; totalNew += n
			lines.append("  edit \(i + 1): replaced \(o) chars → \(n) chars")
		}
		lines.append("  total: replaced \(totalOld) chars → \(totalNew) chars")
		return ToolResult(lines.joined(separator: "\n"))
	}

	private func deleteDoc(_ args: [String: Any]) throws -> ToolResult {
		let name = try string(args, "name")
		let path = try PathSafety.resolveDocName(docsDir: docsDir, name: name)
		let fm = FileManager.default
		guard fm.fileExists(atPath: path.path) else {
			return ToolResult("❌ Document not found: \(name)", isError: true)
		}
		let rel = PathSafety.relativePath(of: path, under: docsDir)
		try fm.removeItem(at: path)
		return ToolResult("🗑️ Deleted docs/\(rel)")
	}

	// MARK: - project tools (read-only)

	private func readFile(_ args: [String: Any]) throws -> ToolResult {
		let rawPath = try string(args, "path")
		let path = try PathSafety.safeResolve(base: root, relative: rawPath)
		let fm = FileManager.default

		var isDir: ObjCBool = false
		guard fm.fileExists(atPath: path.path, isDirectory: &isDir) else {
			return ToolResult("❌ File not found: \(rawPath)", isError: true)
		}
		if isDir.boolValue {
			return ToolResult("❌ Path is a directory. Use list_directory instead.", isError: true)
		}

		let rel = PathSafety.relativePath(of: path, under: root)

		// Binary files get a metadata response, not a dead-end error. One sniff
		// buffer serves both the NUL check and magic-number type detection.
		let sniff = PathSafety.sniff(path) ?? Data()
		if PathSafety.isBinaryExtension(path) || PathSafety.looksBinary(sniff) {
			return binaryMetadata(path, rel: rel, sniff: sniff)
		}

		return try textFileResult(path: path, display: rel, range: readRange(args))
	}

	private func listDirectory(_ args: [String: Any]) throws -> ToolResult {
		let dirStr = (args["path"] as? String) ?? ""
		let maxDepth = (args["depth"] as? Int) ?? 1
		let fm = FileManager.default

		let dir = dirStr.isEmpty ? root : try PathSafety.safeResolve(base: root, relative: dirStr)
		var isDir: ObjCBool = false
		guard fm.fileExists(atPath: dir.path, isDirectory: &isDir) else {
			return ToolResult("❌ Directory not found: \(dirStr.isEmpty ? "/" : dirStr)", isError: true)
		}
		if !isDir.boolValue {
			return ToolResult("❌ Not a directory: \(dirStr)", isError: true)
		}

		var entries: [String] = []
		listDirRecursive(base: dir, current: dir, maxDepth: maxDepth, currentDepth: 0, into: &entries)

		let rel = dir.standardizedFileURL.path == root.standardizedFileURL.path
			? "." : PathSafety.relativePath(of: dir, under: root)
		let header = "📂 \(rel)/  (\(entries.count) entries, depth=\(maxDepth))\n"
		return ToolResult(header + entries.joined(separator: "\n"))
	}

	private func listDirRecursive(base: URL, current: URL, maxDepth: Int, currentDepth: Int, into entries: inout [String]) {
		if currentDepth >= maxDepth { return }
		let fm = FileManager.default
		guard let raw = try? fm.contentsOfDirectory(at: current, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []) else {
			return
		}

		// Sort: directories first, then by name.
		let items = raw.sorted { a, b in
			let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
			let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
			if aDir != bDir { return aDir && !bDir }
			return a.lastPathComponent < b.lastPathComponent
		}

		for item in items {
			let name = item.lastPathComponent
			if Skip.dirs.contains(name) || name.hasPrefix(".") { continue }

			let rel = PathSafety.relativePath(of: item, under: base)
			let indent = String(repeating: "  ", count: currentDepth)
			let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

			if isDir {
				let children = (try? fm.contentsOfDirectory(atPath: item.path)) ?? []
				let childCount = children.filter { !$0.hasPrefix(".") }.count
				entries.append("\(indent)📂 \(rel)/  (\(childCount) items)")
				listDirRecursive(base: base, current: item, maxDepth: maxDepth, currentDepth: currentDepth + 1, into: &entries)
			} else {
				// compiledExtensions, not the full binary set: listings must keep
				// showing assets (.png, .pdf, …) exactly as before.
				if Skip.compiledExtensions.contains("." + item.pathExtension.lowercased()) { continue }
				let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
				entries.append(String(format: "%@📄 %@  (%.1f KB)", indent, rel, Double(size) / 1024.0))
			}
		}
	}

	private func searchFiles(_ args: [String: Any]) throws -> ToolResult {
		let pattern = try string(args, "pattern")
		let searchPathStr = (args["path"] as? String) ?? ""
		let caseSensitive = (args["case_sensitive"] as? Bool) ?? true
		let fm = FileManager.default

		let searchRoot = searchPathStr.isEmpty ? root : try PathSafety.safeResolve(base: root, relative: searchPathStr)
		var isDir: ObjCBool = false
		guard fm.fileExists(atPath: searchRoot.path, isDirectory: &isDir) else {
			return ToolResult("❌ Path not found: \(searchPathStr)", isError: true)
		}

		let regexOpts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
		guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOpts) else {
			return ToolResult("❌ Invalid regex: \(pattern)", isError: true)
		}

		// Gather candidate files with sizes (sorted for deterministic output).
		// Binary classification happens in the match loop, not here — binaries
		// stay in the candidate list so their names can still match.
		var files: [(url: URL, size: Int)] = []
		if isDir.boolValue {
			// Directory: walk it. (FileManager.enumerator returns nil for a file URL,
			// which is what previously made file-scoped searches silently return nothing.)
			if let en = fm.enumerator(at: searchRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
				for case let url as URL in en {
					if url.pathComponents.contains(where: { Skip.dirs.contains($0) }) { continue }
					let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
					guard vals?.isRegularFile == true else { continue }
					files.append((url, vals?.fileSize ?? 0))
				}
			}
			files.sort { $0.url.path < $1.url.path }
		} else {
			// File: search just this one file. Feeds the same match loop below,
			// so a binary file gets the honest name-match/skip treatment instead
			// of an error.
			files = [(searchRoot, (try? fileSize(searchRoot)) ?? 0)]
		}

		func matches(_ line: String) -> Bool {
			let ns = line as NSString
			return regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil
		}

		var results: [String] = []
		var skippedBinaryCount = 0, skippedBinaryBytes = 0
		var skippedLargeCount = 0, skippedLargeBytes = 0
		outer: for f in files {
			let rel = PathSafety.relativePath(of: f.url, under: root)

			// Classify: extension first (free), NUL sniff second (8 KB). Content
			// of binaries is never read, but their names still count as results.
			func recordBinary() {
				skippedBinaryCount += 1
				skippedBinaryBytes += f.size
				if matches(rel) {
					results.append("  📦 \(rel)  (binary — name match)")
				}
			}
			if PathSafety.isBinary(f.url) {
				recordBinary()
				if results.count >= Skip.maxSearchResults { break outer }
				continue
			}
			if f.size > Skip.maxReadSize {
				skippedLargeCount += 1
				skippedLargeBytes += f.size
				continue
			}
			guard let text = try? String(contentsOf: f.url, encoding: .utf8) else {
				// Passed the sniff but isn't UTF-8 — treat like a binary skip.
				recordBinary()
				if results.count >= Skip.maxSearchResults { break outer }
				continue
			}
			var lineNo = 0
			text.enumerateLines { line, stop in
				lineNo += 1
				if matches(line) {
					results.append("  \(rel):\(lineNo)  \(line.trimmingCharacters(in: .whitespaces))")
					if results.count >= Skip.maxSearchResults { stop = true }
				}
			}
			if results.count >= Skip.maxSearchResults { break outer }
		}

		// Honesty footer: report what was not looked at.
		var footer = ""
		if skippedBinaryCount > 0 {
			footer += "\n(skipped content of \(skippedBinaryCount) binary file\(skippedBinaryCount == 1 ? "" : "s") — \(Self.formatMB(skippedBinaryBytes)) not searched)"
		}
		if skippedLargeCount > 0 {
			footer += "\n(skipped \(skippedLargeCount) file\(skippedLargeCount == 1 ? "" : "s") over the read-size cap — \(Self.formatMB(skippedLargeBytes)) not searched)"
		}

		if results.isEmpty {
			return ToolResult("🔍 No matches for: \(pattern)" + footer)
		}
		let truncated = results.count >= Skip.maxSearchResults ? " (truncated)" : ""
		let header = "🔍 \(results.count) match(es) for '\(pattern)'\(truncated):\n"
		return ToolResult(header + results.joined(separator: "\n") + footer)
	}

	private func getProjectIndex() throws -> ToolResult {
		let fm = FileManager.default
		guard fm.fileExists(atPath: projectIndex.path) else {
			return ToolResult("❌ project-index.md not found at project root.\nCreate it with: write a project-index.md in the project root", isError: true)
		}
		let content = try String(contentsOf: projectIndex, encoding: .utf8)
		return ToolResult("📋 project-index.md\n\n\(content)")
	}

	// MARK: - Helpers

	private func string(_ args: [String: Any], _ key: String) throws -> String {
		guard let v = args[key] as? String else {
			throw BridgeError("Missing required argument: \(key)")
		}
		return v
	}

	private func fileSize(_ url: URL) throws -> Int {
		let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
		return (attrs[.size] as? Int) ?? 0
	}

	private func tooLarge(_ url: URL, hint: Bool = false) -> String {
		let kb = (try? Double(fileSize(url)) / 1024.0) ?? 0
		let maxKB = Double(Skip.maxReadSize) / 1024.0
		var msg = String(format: "❌ File too large: %.0f KB (max %.0f KB)", kb, maxKB)
		if hint {
			msg += ". Use offset/limit to read a range, e.g. offset=1, limit=500."
		}
		return msg
	}

	private static func formatMB(_ bytes: Int) -> String {
		String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
	}

	// MARK: - Ranged reads

	private struct ReadRange {
		let offset: Int   // 1-based first line
		let limit: Int?   // nil = to EOF
	}

	/// Parse optional offset/limit arguments. Returns nil when neither is given
	/// (plain whole-file read, unchanged behavior).
	private func readRange(_ args: [String: Any]) throws -> ReadRange? {
		let offset = args["offset"] as? Int
		let limit = args["limit"] as? Int
		if offset == nil && limit == nil { return nil }
		if let o = offset, o < 1 { throw BridgeError("offset must be >= 1 (got \(o))") }
		if let l = limit, l < 1 { throw BridgeError("limit must be >= 1 (got \(l))") }
		return ReadRange(offset: offset ?? 1, limit: limit)
	}

	/// Produce the result for a text file: plain whole-file read when no range
	/// is given (and the file fits), otherwise a line-ranged read. Large files
	/// require a range; ranged reads stream incrementally and never load the
	/// whole file into memory.
	private func textFileResult(path: URL, display: String, range: ReadRange?) throws -> ToolResult {
		guard let range else {
			if try fileSize(path) > Skip.maxReadSize {
				return ToolResult(tooLarge(path, hint: true), isError: true)
			}
			let content = try String(contentsOf: path, encoding: .utf8)
			return ToolResult("📄 \(display)\n\n\(content)")
		}
		return try rangedRead(path: path, display: display, range: range)
	}

	/// Stream the file line by line, collecting only the requested range.
	/// Bounded memory: 64 KB chunks in, at most maxReadSize of collected output.
	private func rangedRead(path: URL, display: String, range: ReadRange) throws -> ToolResult {
		guard let fh = try? FileHandle(forReadingFrom: path) else {
			throw BridgeError("Cannot open file: \(display)")
		}
		defer { try? fh.close() }

		let lastWanted = range.limit.map { range.offset + $0 - 1 }
		var selected: [String] = []
		var selectedBytes = 0
		var outputCapped = false
		var lineNo = 0
		var lastCollected = 0

		func take(_ lineData: Data) {
			lineNo += 1
			guard lineNo >= range.offset, lastWanted.map({ lineNo <= $0 }) ?? true, !outputCapped else { return }
			var d = lineData
			if d.last == 0x0D { d = d.dropLast() }   // CRLF
			if selectedBytes + d.count > Skip.maxReadSize {
				outputCapped = true
				return
			}
			selected.append(String(decoding: d, as: UTF8.self))
			selectedBytes += d.count
			lastCollected = lineNo
		}

		var carry = Data()
		let newline = Data([0x0A])
		while let chunk = try? fh.read(upToCount: 64 * 1024), !chunk.isEmpty {
			carry.append(chunk)
			while let nl = carry.range(of: newline) {
				take(carry.subdata(in: carry.startIndex..<nl.lowerBound))
				carry.removeSubrange(carry.startIndex..<nl.upperBound)
			}
		}
		if !carry.isEmpty { take(carry) }

		if range.offset > lineNo {
			return ToolResult("❌ offset \(range.offset) is past end of file: \(display) has \(lineNo) line\(lineNo == 1 ? "" : "s").", isError: true)
		}

		let end = lastCollected
		var out = "📄 \(display)  (lines \(range.offset)–\(end) of \(lineNo))\n\n"
		out += selected.joined(separator: "\n")
		if outputCapped {
			out += String(format: "\n\n(output capped at %.0f KB — narrow the range to read further)", Double(Skip.maxReadSize) / 1024.0)
		} else if end < lineNo {
			out += "\n\n(\(lineNo - end) more line\(lineNo - end == 1 ? "" : "s") — continue with offset=\(end + 1))"
		}
		return ToolResult(out)
	}

	/// Metadata response for a binary file: type (magic numbers), size, mtime.
	private func binaryMetadata(_ url: URL, rel: String, sniff: Data) -> ToolResult {
		let size = (try? fileSize(url)) ?? 0
		let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
		let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
		return ToolResult("""
		📦 \(rel)
			type: \(PathSafety.binaryTypeDescription(sniff))
			size: \(String(format: "%.1f KB", Double(size) / 1024.0))
			modified: \(Self.utcStamp(mtime))
		""")
	}

	private static func occurrences(of needle: String, in haystack: String) -> Int {
		guard !needle.isEmpty else { return 0 }
		var count = 0
		var searchRange = haystack.startIndex..<haystack.endIndex
		while let r = haystack.range(of: needle, range: searchRange) {
			count += 1
			searchRange = r.upperBound..<haystack.endIndex
		}
		return count
	}

	private static func utcStamp(_ date: Date) -> String {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.timeZone = TimeZone(identifier: "UTC")
		f.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return f.string(from: date) + " UTC"
	}
}
