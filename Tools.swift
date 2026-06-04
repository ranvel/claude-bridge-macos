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
	private var docsDir: URL { root.appendingPathComponent("docs") }
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
				"description": "Read a document from docs/ by name. Case-sensitive. You can omit the .md extension. Examples: 'marketing', 'branding/colors.md'",
				"inputSchema": [
					"type": "object",
					"properties": [
						"name": ["type": "string", "description": "Document name or path relative to docs/"],
					],
					"required": ["name"],
				],
			],
			[
				"name": "write_doc",
				"description": "Create or overwrite a document in docs/. Subdirectories are created automatically. If no extension is given, .md is appended.",
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
				"description": "Update a section of an existing document in docs/. Finds old_text and replaces it with new_text. old_text must match exactly (case-sensitive).",
				"inputSchema": [
					"type": "object",
					"properties": [
						"name": ["type": "string", "description": "Document name or path relative to docs/"],
						"old_text": ["type": "string", "description": "Exact text to find (must appear exactly once)"],
						"new_text": ["type": "string", "description": "Replacement text"],
					],
					"required": ["name", "old_text", "new_text"],
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
				"description": "Read any file from the project (read-only). Path is relative to project root. Case-sensitive.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"path": ["type": "string", "description": "File path relative to project root"],
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
				"description": "Search for a pattern across project files (like grep). Returns matching lines with file paths and line numbers. Searches text files only, skips binaries and build artifacts.",
				"inputSchema": [
					"type": "object",
					"properties": [
						"pattern": ["type": "string", "description": "Search pattern (regex supported)"],
						"path": ["type": "string", "description": "Subdirectory to search in (relative to project root, empty = all)", "default": ""],
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
		if try fileSize(path) > Skip.maxReadSize {
			return ToolResult(tooLarge(path), isError: true)
		}
		let content = try String(contentsOf: path, encoding: .utf8)
		let rel = PathSafety.relativePath(of: path, under: docsDir)
		return ToolResult("📄 docs/\(rel)\n\n\(content)")
	}

	private func writeDoc(_ args: [String: Any]) throws -> ToolResult {
		let name = try string(args, "name")
		let content = try string(args, "content")
		let path = try PathSafety.resolveDocName(docsDir: docsDir, name: name)
		let fm = FileManager.default

		try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
		let existed = fm.fileExists(atPath: path.path)
		try content.data(using: .utf8)?.write(to: path)
		let rel = PathSafety.relativePath(of: path, under: docsDir)
		let verb = existed ? "Updated" : "Created"
		return ToolResult("✅ \(verb) docs/\(rel) (\(content.unicodeScalars.count) chars)")
	}

	private func updateDoc(_ args: [String: Any]) throws -> ToolResult {
		let name = try string(args, "name")
		let oldText = try string(args, "old_text")
		let newText = try string(args, "new_text")
		let path = try PathSafety.resolveDocName(docsDir: docsDir, name: name)
		let fm = FileManager.default
		guard fm.fileExists(atPath: path.path) else {
			return ToolResult("❌ Document not found: \(name)", isError: true)
		}

		let content = try String(contentsOf: path, encoding: .utf8)
		let rel = PathSafety.relativePath(of: path, under: docsDir)
		let count = Self.occurrences(of: oldText, in: content)

		if count == 0 {
			return ToolResult("❌ old_text not found in docs/\(rel)", isError: true)
		}
		if count > 1 {
			return ToolResult("❌ old_text appears \(count) times (must be unique). Add more context to disambiguate.", isError: true)
		}

		guard let range = content.range(of: oldText) else {
			return ToolResult("❌ old_text not found in docs/\(rel)", isError: true)
		}
		let updated = content.replacingCharacters(in: range, with: newText)
		try updated.data(using: .utf8)?.write(to: path)
		return ToolResult("✅ Updated docs/\(rel) (replaced \(oldText.unicodeScalars.count) chars → \(newText.unicodeScalars.count) chars)")
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
		if try fileSize(path) > Skip.maxReadSize {
			return ToolResult(tooLarge(path), isError: true)
		}
		if Skip.extensions.contains("." + path.pathExtension.lowercased()) {
			return ToolResult("❌ Binary/compiled file, cannot read: \(rawPath)", isError: true)
		}
		guard let content = try? String(contentsOf: path, encoding: .utf8) else {
			return ToolResult("❌ File appears to be binary: \(rawPath)", isError: true)
		}
		let rel = PathSafety.relativePath(of: path, under: root)
		return ToolResult("📄 \(rel)\n\n\(content)")
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
				if Skip.extensions.contains("." + item.pathExtension.lowercased()) { continue }
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
		guard fm.fileExists(atPath: searchRoot.path) else {
			return ToolResult("❌ Path not found: \(searchPathStr)", isError: true)
		}

		let regexOpts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
		guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOpts) else {
			return ToolResult("❌ Invalid regex: \(pattern)", isError: true)
		}

		// Gather candidate files (sorted for deterministic output).
		var files: [URL] = []
		if let en = fm.enumerator(at: searchRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
			for case let url as URL in en {
				if url.pathComponents.contains(where: { Skip.dirs.contains($0) }) { continue }
				let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
				guard vals?.isRegularFile == true else { continue }
				if Skip.extensions.contains("." + url.pathExtension.lowercased()) { continue }
				if (vals?.fileSize ?? 0) > Skip.maxReadSize { continue }
				files.append(url)
			}
		}
		files.sort { $0.path < $1.path }

		var results: [String] = []
		outer: for f in files {
			guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
			let rel = PathSafety.relativePath(of: f, under: root)
			var lineNo = 0
			text.enumerateLines { line, stop in
				lineNo += 1
				let ns = line as NSString
				if regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
					results.append("  \(rel):\(lineNo)  \(line.trimmingCharacters(in: .whitespaces))")
					if results.count >= Skip.maxSearchResults { stop = true }
				}
			}
			if results.count >= Skip.maxSearchResults { break outer }
		}

		if results.isEmpty {
			return ToolResult("🔍 No matches for: \(pattern)")
		}
		let truncated = results.count >= Skip.maxSearchResults ? " (truncated)" : ""
		let header = "🔍 \(results.count) match(es) for '\(pattern)'\(truncated):\n"
		return ToolResult(header + results.joined(separator: "\n"))
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

	private func tooLarge(_ url: URL) -> String {
		let kb = (try? Double(fileSize(url)) / 1024.0) ?? 0
		let maxKB = Double(Skip.maxReadSize) / 1024.0
		return String(format: "❌ File too large: %.0f KB (max %.0f KB)", kb, maxKB)
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
