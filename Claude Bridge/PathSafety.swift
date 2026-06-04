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

	/// File extensions (lowercased, with leading dot) treated as binary.
	static let extensions: Set<String> = [
		".o", ".d", ".pyc", ".pyo", ".class", ".jar",
		".dylib", ".a", ".so", ".metallib",
	]

	/// Max file size we'll read (5 MB).
	static let maxReadSize = 5 * 1024 * 1024

	/// Max search results returned per call.
	static let maxSearchResults = 50
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
