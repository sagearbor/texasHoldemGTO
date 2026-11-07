#!/usr/bin/env bash
# Compiles ios/PulseShared/PulseProtocol.swift (the code the watch app and the
# iPhone bridge both ship) with a small checker and runs it against the shared
# test vectors. macOS + Xcode command line tools only; no simulator needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -O -o "$out/protocol_check" \
  ios/PulseShared/PulseProtocol.swift tool/watch_ios/protocol_check/main.swift
"$out/protocol_check" test/pulse/protocol_vectors.json
