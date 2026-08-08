#!/bin/zsh
# Compile PathSafety.swift + Tools.swift against the test main and run it.
# No XCTest target exists in the project; both files import only Foundation,
# so swiftc can build them directly.
set -e
cd "$(dirname "$0")/.."
mkdir -p Tests/.build
swiftc -o Tests/.build/bridge-tests \
	"Claude Bridge/PathSafety.swift" \
	"Claude Bridge/Tools.swift" \
	Tests/main.swift
exec Tests/.build/bridge-tests
