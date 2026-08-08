# Cici Findings — File Surgery (implemented 2026-08-07)

All three targets from `cici-brief-file-surgery.md` shipped. Build green, all 44 regression assertions pass (`./Tests/run.sh`).

## What shipped

- **Target 1 — binary awareness.** `Skip.extensions` expanded with the full asset/media/archive baseline; `PathSafety.isBinary` (extension check first, then 8 KB NUL sniff via bounded `FileHandle.read(upToCount:)`); `search_files` name-matches binary paths (`📦 … (binary — name match)`) and appends an honesty footer; `read_file` on a binary returns a non-error metadata block with magic-number type (PNG/JPEG/GIF/PDF/ZIP/SQLite/Mach-O/gzip/ICNS), size, and UTC mtime — one sniff buffer serves both the NUL check and type detection.
- **Target 2 — ranged reads.** `offset`/`limit` on `read_file` and `read_doc`; `(lines A–B of N)` header + continuation footer; ranged reads stream in 64 KB chunks (never load the whole file); files over the 5 MB cap require a range and the refusal now names the exit; past-EOF offset errors with the actual line count.
- **Target 3 — batch edits.** `update_doc` accepts an `edits` array (mutually exclusive with the single pair); validate-and-apply in one pass over an in-memory copy with sequential semantics; any failure rejects the whole batch naming the edit index and reason, disk untouched; success reports per-edit and total char deltas.
- `CLAUDE.md` toolset docs updated (binary handling, ranged reads, batch edits, test harness).

## Recon calls made (brief deferred these to judgment)

1. **`.xcassets` stays out of `Skip.dirs`.** Search still walks into asset catalogs: `Contents.json` is useful, searchable text (asset names), and the images inside are caught by the extension check anyway. `.xcassets` remains in the extension set as belt-and-suspenders for oddball flat files.
2. **`Skip.extensions` split into `compiledExtensions ∪ assetExtensions`.** Reason: `list_directory` filters files on the binary set; pointing it at the full expanded set would have silently *hidden* every PNG/PDF from listings — violating "skip the content, never the existence" and regression test 11. `list_directory` now filters on `compiledExtensions` only, keeping its output byte-identical.
3. **Oversized text files get their own footer line** (`skipped N files over the read-size cap — X MB not searched`). They were silently skipped before; the honesty rule (Second Law) applies to them the same as to binaries. They are *not* name-matched — the brief scoped name matching to binaries.
4. **Single-file search of a binary is no longer an error.** Pointing `search_files` at a binary now yields the same name-match/footer treatment as the directory walk, not `❌ cannot search`.
5. **UTF-8 decode failures in search** (file passed the sniff but isn't UTF-8, e.g. Latin-1) count as binary skips — that read-and-fail was exactly the silent dead I/O the brief describes.

## Performance evidence (regression test 1)

- **Bytes:** on this repo, every pre-change search fully read and decode-failed **24.1 MB across 23 binary files** (the brief's ~9 MB estimate counted only the two biggest; the iconset rounds it out). Post-change: 8 KB sniff per file, content never read. The footer now reports exactly this: `(skipped content of 23 binary files — 24.1 MB not searched)`.
- **Wall-clock:** old HEAD vs. new, `-O` builds, 5-iteration average over the real repo, warm page cache: **7.5 ms → 6.5 ms**. Warm cache is the worst case for showing this win — the OS hides the 24 MB of dead reads; cold-cache and network/large-project cases scale with bytes, which dropped ~99.9%.

## Test coverage

`Tests/run.sh` (swiftc harness; no XCTest target existed, and adding one to the pbxproj was more churn than the brief's targets justified) covers all 11 required cases: skip footer, name match, extensionless Mach-O sniff, PNG metadata, ranged reads + header, large-file ranged/unranged, past-EOF, batch apply, batch atomicity (disk verified unchanged), sequential semantics, and byte-identical outputs for pre-existing call shapes.
