#!/usr/bin/env bash
# The rules a compiler cannot check (ARCHITECTURE.md, sections 2 and 9). Fails with the offending lines.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0

fail() { echo "check-rules: $1" >&2; echo "$2" | sed 's/^/    /' >&2; status=1; }

# 1. No network.
found=$(grep -rnE 'URLSession|NWConnection|CFNetwork|WKWebView|^import Network' Sources || true)
[ -z "$found" ] || fail "Sorello makes no network connections" "$found"

# 2. No logging outside Diagnostics and the two command-line tools.
found=$(grep -rnE '(^|[^A-Za-z_.])(print|debugPrint|NSLog|os_log)\(|Logger\(' Sources \
  | grep -vE '^Sources/(SorelloSnapshots|SorelloTranscribe)/|/Diagnostics\.swift:' || true)
[ -z "$found" ] || fail "log only through Diagnostics, which cannot carry content" "$found"

# 3. Neutral, pure modules import no UI, audio or model framework.
found=$(grep -rnE '^(@preconcurrency )?import (AppKit|SwiftUI|UIKit|AVFoundation|CoreML|Cocoa)' \
  Sources/DictationCore Sources/TextRules Sources/DesignCore Sources/DictionaryKit || true)
[ -z "$found" ] || fail "pure modules import only Foundation" "$found"
found=$(grep -rnE '^(@preconcurrency )?import (AppKit|SwiftUI|Cocoa)' Sources/SpeechEngine Sources/Persistence || true)
[ -z "$found" ] || fail "neutral modules must also build for iOS" "$found"

# 4. Every @unchecked Sendable says what makes it safe, on its line or within the three lines after or before.
found=$(grep -rnE '@unchecked Sendable' Sources | while IFS=: read -r file line _; do
  start=$((line > 3 ? line - 3 : 1))
  sed -n "${start},$((line + 3))p" "$file" | grep -q 'Safe:' || echo "$file:$line"
done)
[ -z "$found" ] || fail "@unchecked Sendable needs a '// Safe:' comment naming the lock or queue" "$found"

# 5. The old names are gone.
found=$(grep -rniE 'localflow|freeflow|wilderness' Sources Config scripts Makefile 2>/dev/null \
  | grep -v '^scripts/check-rules.sh:' || true)
[ -z "$found" ] || fail "an earlier product's name is still in the code" "$found"

# 6. No model weights, audio or build output in Git.
if git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  found=$(git ls-files | grep -E '\.(mlmodelc|mlpackage|f32bin|f16bin|safetensors|wav|caf|m4a|dmg)(/|$)' || true)
  [ -z "$found" ] || fail "weights, audio and disk images stay out of Git" "$found"
fi

exit $status
