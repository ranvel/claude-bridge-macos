//
//  PathSafety.swift
//  ClaudeBridge
//
//  Path resolution + escape protection, ported faithfully from the
//  Python server's safe_resolve / resolve_doc_name.
//

import Foundation

/// Thrown when a requested path tries to escape the project root.
struct BridgeError: Error {
	let message: String
	init(_ message: String) { self.message = message }
}

enum Skip {
	/// Directory names to skip during listing and search.
	static let dirs: Set<String> = [
		".git", "node_modules", "__pycache__", ".build", "Build",
		"DerivedData", ".swiftpm", ".DS_Store", "xcuserdata",
	]

	/// Compiled build artifacts. Kept as its own set because list_directory
	/// hides these from listings (historical behavior) but must keep showing
	/// assets like .png — only search/read use the full binary set below.
	static let compiledExtensions: Set<String> = [
		".o", ".d", ".pyc", ".pyo", ".class", ".jar",
		".dylib", ".a", ".so", ".metallib",
	]

	/// Asset/media/archive formats whose content is never worth reading.
	static let assetExtensions: Set<String> = [
		".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".icns", ".ico", ".bmp", ".tiff", ".tif",
		".pdf", ".zip", ".gz", ".tar", ".xz", ".bz2", ".7z", ".dmg", ".pkg",
		".sqlite", ".sqlite3", ".db", ".realm",
		".mp3", ".m4a", ".aac", ".flac", ".alac", ".wav", ".aiff", ".aif", ".ogg", ".caf",
		".mp4", ".mov", ".avi", ".mkv",
		".ttf", ".otf", ".woff", ".woff2",
		".car", ".nib", ".storyboardc", ".xcassets",
	]

	/// File extensions (lowercased, with leading dot) treated as binary.
	static let extensions: Set<String> = compiledExtensions.union(assetExtensions)

	/// Max file size we'll read (5 MB).
	static let maxReadSize = 5 * 1024 * 1024

	/// Max search results returned per call.
	static let maxSearchResults = 50

	/// Bytes read when sniffing a file for binary content (NUL bytes / magic numbers).
	static let sniffLength = 8192
}

enum PathSafety {
	/// Resolve `relative` against `base`, rejecting anything that escapes the base.
	/// Mirrors the Python safe_resolve (but uses a path-component-aware prefix check).
	static func safeResolve(base: URL, relative: String) throws -> URL {
		let baseStd = base.standardizedFileURL
		// If `relative` is absolute, URL ignores base — the escape check below catches it.
		let target = URL(fileURLWithPath: relative, relativeTo: baseStd).standardizedFileURL

		let basePath = baseStd.path
		let targetPath = target.path
		if targetPath == basePath || targetPath.hasPrefix(basePath + "/") {
			return target
		}
		throw BridgeError("Path escapes allowed root: \(relative)")
	}

	/// Resolve a doc name to a path inside `docsDir`. Case-sensitive.
	/// 1. exact match  2. with .md appended  3. default to .md for writes.
	static func resolveDocName(docsDir: URL, name: String) throws -> URL {
		let exact = try safeResolve(base: docsDir, relative: name)
		if FileManager.default.fileExists(atPath: exact.path) {
			return exact
		}

		if !name.hasSuffix(".md") {
			let withExt = try safeResolve(base: docsDir, relative: name + ".md")
			if FileManager.default.fileExists(atPath: withExt.path) {
				return withExt
			}
		}

		// For write operations, default to .md when no extension was given.
		if exact.pathExtension.isEmpty {
			return try safeResolve(base: docsDir, relative: name + ".md")
		}
		return exact
	}

	// MARK: - Binary detection

	/// True if the file's extension is in the known-binary set. Free check — no I/O.
	static func isBinaryExtension(_ url: URL) -> Bool {
		Skip.extensions.contains("." + url.pathExtension.lowercased())
	}

	/// First `Skip.sniffLength` bytes of the file. Bounded read — never loads
	/// the whole file. Returns nil if the file can't be opened.
	static func sniff(_ url: URL) -> Data? {
		guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? fh.close() }
		return (try? fh.read(upToCount: Skip.sniffLength)) ?? Data()
	}

	/// True if `data` (a sniff buffer) looks binary: contains a NUL byte.
	static func looksBinary(_ data: Data) -> Bool {
		data.contains(0)
	}

	/// Extension check first (free), NUL sniff second (cheap, 8 KB).
	static func isBinary(_ url: URL) -> Bool {
		if isBinaryExtension(url) { return true }
		guard let data = sniff(url) else { return false }
		return looksBinary(data)
	}

	/// Human-readable file type from magic numbers in a sniff buffer.
	static func binaryTypeDescription(_ data: Data) -> String {
		func starts(_ bytes: [UInt8]) -> Bool {
			data.count >= bytes.count && data.prefix(bytes.count).elementsEqual(bytes)
		}
		if starts([0x89, 0x50, 0x4E, 0x47]) { return "PNG image" }
		if starts([0xFF, 0xD8, 0xFF]) { return "JPEG image" }
		if starts(Array("GIF8".utf8)) { return "GIF image" }
		if starts(Array("%PDF".utf8)) { return "PDF document" }
		if starts([0x50, 0x4B, 0x03, 0x04]) { return "ZIP archive" }
		if starts(Array("SQLite format 3".utf8) + [0x00]) { return "SQLite database" }
		if starts([0xCF, 0xFA, 0xED, 0xFE]) { return "Mach-O binary" }
		if starts([0xCA, 0xFE, 0xBA, 0xBE]) { return "Mach-O universal binary" }
		if starts([0x1F, 0x8B]) { return "gzip archive" }
		if starts(Array("icns".utf8)) { return "ICNS icon" }
		return "binary (unknown type)"
	}

	/// Path of `url` relative to `root` (e.g. "docs/spec.md"). Falls back to the
	/// last component if `url` is not under `root`.
	static func relativePath(of url: URL, under root: URL) -> String {
		let rootPath = root.standardizedFileURL.path
		let p = url.standardizedFileURL.path
		if p == rootPath { return "." }
		if p.hasPrefix(rootPath + "/") {
			return String(p.dropFirst(rootPath.count + 1))
		}
		return url.lastPathComponent
	}
}
