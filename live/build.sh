#!/bin/zsh
# transcribe.swift → bin/transcribe 빌드. Xcode Command Line Tools 만 있으면 된다(macOS 26+).
set -eu
D="${0:A:h}"
mkdir -p "$D/bin"
xcrun swiftc -parse-as-library -O "$D/transcribe.swift" -o "$D/bin/transcribe"
echo "✅ $D/bin/transcribe"
