//
//  main.swift — Claude Bridge regression tests (file-surgery brief)
//
//  Compiled directly against PathSafety.swift + Tools.swift by Tests/run.sh
//  (no XCTest target in the project; both files import only Foundation).
//  Exit code 0 = all passed.
//

import Foundation

var failures = 0
var current = ""

func suite(_ name: String) {
	current = name
	print("\n— \(name)")
}

func expect(_ cond: Bool, _ msg: String) {
	if cond {
		print("  ✓ \(msg)")
	} else {
		failures += 1
		print("  ✗ FAIL: \(msg)")
	}
}

func text(_ r: ToolResult) -> String { r.blocks.joined(separator: "\n") }

// MARK: - Fixture

let fm = FileManager.default
let fixture = fm.temporaryDirectory.appendingPathComponent("bridge-tests-\(UUID().uuidString)")
try fm.createDirectory(at: fixture.appendingPathComponent("docs"), withIntermediateDirectories: true)
try fm.createDirectory(at: fixture.appendingPathComponent("src"), withIntermediateDirectories: true)
try fm.createDirectory(at: fixture.appendingPathComponent("assets"), withIntermediateDirectories: true)
defer { try? fm.removeItem(at: fixture) }

func write(_ rel: String, _ data: Data) {
	try! data.write(to: fixture.appendingPathComponent(rel))
}
func write(_ rel: String, _ s: String) {
	write(rel, s.data(using: .utf8)!)
}

// Text file, 10 lines.
write("src/hello.swift", (1...10).map { "l\($0)" }.joined(separator: "\n") + "\n")

// >4 MB "PNG": magic + zeros. Extension AND sniff both classify it.
var bigPNG = Data([0x89, 0x50, 0x4E, 0x47])
bigPNG.append(Data(count: 4_500_000))
write("assets/big.png", bigPNG)

// Small real-magic PNG.
write("assets/little.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(count: 64))

// Extensionless Mach-O-ish binary containing a searchable ASCII needle.
var mystery = Data([0xCF, 0xFA, 0xED, 0xFE])
mystery.append(Data(count: 512))
mystery.append("SECRETNEEDLE".data(using: .utf8)!)
mystery.append(Data(count: 512))
write("assets/mysteryfile", mystery)

// Text file over the 5 MB read cap (~5.6 MB).
var bigTxt = ""
var bigTxtLines = 0
while bigTxt.utf8.count <= Skip.maxReadSize + 500_000 {
	bigTxtLines += 1
	bigTxt += "row \(bigTxtLines) \(String(repeating: "x", count: 60))\n"
}
write("src/large.txt", bigTxt)

write("docs/t8.md", "alpha beta gamma\n")
write("docs/t9.md", "alpha beta gamma\n")
write("docs/t10.md", "hello world\n")
write("docs/t11.md", "alpha beta gamma\n")

let tools = Tools(rootPath: fixture.path)
func call(_ name: String, _ args: [String: Any]) -> ToolResult {
	tools.call(name: name, arguments: args)
}

// MARK: - 1. Skip footer + timing on a dir with a >4 MB binary

suite("1. search skip footer + bytes not read")
let t0 = Date()
let r1 = call("search_files", ["pattern": "zzz_definitely_no_match"])
let elapsed = Date().timeIntervalSince(t0)
expect(!r1.isError, "search succeeds")
expect(text(r1).contains("(skipped content of 3 binary files —"), "footer counts 3 binaries (big.png, little.png, mysteryfile)")
expect(text(r1).contains("MB not searched)"), "footer reports MB not searched")
print("  ℹ︎ timing note: search over fixture (incl. 4.5 MB binary) took \(String(format: "%.3f", elapsed))s; binary content bytes were sniffed (8 KB each), not read")

// MARK: - 2. Binary filename matching

suite("2. binary name match")
let r2 = call("search_files", ["pattern": "big"])
expect(text(r2).contains("📦 assets/big.png  (binary — name match)"), "name-match line for assets/big.png")
expect(text(r2).contains("over the read-size cap"), "oversized text file reported in footer")
expect(!text(r2).contains("large.txt:"), "no content hits from the oversized text file")

// MARK: - 3. Extensionless binary sniffed, content not regexed

suite("3. NUL sniff on extensionless binary")
let r3 = call("search_files", ["pattern": "SECRETNEEDLE"])
expect(!text(r3).contains("mysteryfile:"), "no content match lines from mysteryfile")
expect(text(r3).contains("No matches"), "needle inside binary is not found")
expect(text(r3).contains("skipped content of"), "skip footer present even on the No-matches case")

// MARK: - 4. read_file on a PNG → metadata, non-error

suite("4. binary metadata from read_file")
let r4 = call("read_file", ["path": "assets/little.png"])
expect(!r4.isError, "non-error response")
expect(text(r4).contains("📦 assets/little.png"), "📦 header")
expect(text(r4).contains("type: PNG image"), "magic-number type detected")
expect(text(r4).contains("size:"), "size present")
expect(text(r4).contains("UTC"), "mtime present (UTC)")
let r4b = call("read_file", ["path": "assets/mysteryfile"])
expect(!r4b.isError && text(r4b).contains("type: Mach-O binary"), "Mach-O magic detected on extensionless file")

// MARK: - 5. Ranged read, header + footer

suite("5. ranged read_file")
let r5 = call("read_file", ["path": "src/hello.swift", "offset": 3, "limit": 4])
expect(text(r5).contains("📄 src/hello.swift  (lines 3–6 of 10)"), "range header correct")
expect(text(r5).contains("l3\nl4\nl5\nl6"), "correct lines returned")
expect(text(r5).contains("(4 more lines — continue with offset=7)"), "continuation footer")
let r5b = call("read_doc", ["name": "t8", "offset": 1, "limit": 1])
expect(text(r5b).contains("📄 docs/t8.md  (lines 1–1 of 1)"), "read_doc ranged too")

// MARK: - 6. Large file: ranged succeeds, unranged errors with hint

suite("6. large-file behavior")
let r6a = call("read_file", ["path": "src/large.txt", "offset": 1, "limit": 5])
expect(!r6a.isError, "ranged read of >5 MB file succeeds")
expect(text(r6a).contains("(lines 1–5 of \(bigTxtLines))"), "header shows true total (\(bigTxtLines) lines)")
expect(text(r6a).contains("row 1 ") && text(r6a).contains("row 5 "), "correct rows")
let r6b = call("read_file", ["path": "src/large.txt"])
expect(r6b.isError, "unranged read still refuses")
expect(text(r6b).contains("Use offset/limit to read a range, e.g. offset=1, limit=500."), "error points at the exit")

// MARK: - 7. offset past EOF

suite("7. offset past EOF")
let r7 = call("read_file", ["path": "src/hello.swift", "offset": 42])
expect(r7.isError, "past-EOF is an error, not empty success")
expect(text(r7).contains("has 10 lines"), "error states actual line count")

// MARK: - 8. update_doc batch, all valid

suite("8. batch edits apply")
let r8 = call("update_doc", ["name": "t8", "edits": [
	["old_text": "alpha", "new_text": "A"],
	["old_text": "gamma", "new_text": "GG"],
]])
expect(!r8.isError, "batch succeeds")
expect(text(r8).contains("✅ Updated docs/t8.md (2 edits)"), "summary header")
expect(text(r8).contains("edit 1: replaced 5 chars → 1 chars"), "per-edit delta 1")
expect(text(r8).contains("edit 2: replaced 5 chars → 2 chars"), "per-edit delta 2")
expect(text(r8).contains("total: replaced 10 chars → 3 chars"), "total delta")
expect(try! String(contentsOf: fixture.appendingPathComponent("docs/t8.md"), encoding: .utf8) == "A beta GG\n", "content on disk correct")

// MARK: - 9. batch atomicity: one bad edit → no write

suite("9. batch atomicity")
let before9 = try! String(contentsOf: fixture.appendingPathComponent("docs/t9.md"), encoding: .utf8)
let r9 = call("update_doc", ["name": "t9", "edits": [
	["old_text": "alpha", "new_text": "A"],
	["old_text": "NOPE_NOT_THERE", "new_text": "X"],
]])
expect(r9.isError, "batch rejected")
expect(text(r9).contains("edit 2 of 2"), "error names the failing edit index")
expect(text(r9).contains("not found"), "…and the reason")
expect(try! String(contentsOf: fixture.appendingPathComponent("docs/t9.md"), encoding: .utf8) == before9, "file on disk unchanged")
let r9b = call("update_doc", ["name": "t9", "edits": [
	["old_text": "a", "new_text": "X"],
]])
expect(r9b.isError && text(r9b).contains("appears") && text(r9b).contains("times"), "ambiguous old_text reports count")

// MARK: - 10. sequential semantics

suite("10. sequential semantics")
let r10 = call("update_doc", ["name": "t10", "edits": [
	["old_text": "hello", "new_text": "goodbye"],
	["old_text": "goodbye world", "new_text": "goodbye moon"],
]])
expect(!r10.isError, "edit 2 matches text created by edit 1")
expect(try! String(contentsOf: fixture.appendingPathComponent("docs/t10.md"), encoding: .utf8) == "goodbye moon\n", "content correct")

// MARK: - 11. existing call shapes unchanged

suite("11. no regressions on plain calls")
let r11a = call("update_doc", ["name": "t11", "old_text": "beta", "new_text": "BETA!!!"])
expect(text(r11a) == "✅ Updated docs/t11.md (replaced 4 chars → 7 chars)", "single-pair update_doc message byte-identical")
let r11b = call("read_file", ["path": "src/hello.swift"])
expect(text(r11b) == "📄 src/hello.swift\n\n" + (1...10).map { "l\($0)" }.joined(separator: "\n") + "\n", "plain read_file output byte-identical")
let r11c = call("search_files", ["pattern": "l3", "path": "src/hello.swift"])
expect(text(r11c) == "🔍 1 match(es) for 'l3':\n  src/hello.swift:3  l3", "plain search output byte-identical (no footer when nothing skipped)")
let r11d = call("update_doc", ["name": "t11"])
expect(r11d.isError && text(r11d).contains("Missing required argument: old_text"), "missing-args error unchanged")
let r11e = call("update_doc", ["name": "t11", "old_text": "a", "new_text": "b", "edits": [["old_text": "a", "new_text": "b"]]])
expect(r11e.isError && text(r11e).contains("not both"), "both forms at once rejected")

// MARK: - Done

print("")
if failures == 0 {
	print("ALL TESTS PASSED")
	exit(0)
} else {
	print("\(failures) FAILURE(S)")
	exit(1)
}
