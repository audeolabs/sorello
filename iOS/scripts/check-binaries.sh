#!/bin/sh
# Checks what the app's three executables link (ARCHITECTURE.md, "Privacy and security invariants", and
# ../ARCHITECTURE.md, section 13):
# - none of them names a networking API, as an undefined symbol or as a linked library: the iPhone app opens no
#   network connection and holds no networking code;
# - the keyboard holds nothing of SpeechEngine, DictionaryKit or DictationCore, so it cannot reach the model or the
#   dictionary, and the Live Activity nothing of any shared module.
# It reads the executables only. Prints every failure and exits 1 if there is any.
#
# Usage: check-binaries.sh APP KEYBOARD ACTIVITY   (the three executables)
set -u

[ $# -eq 3 ] || { echo "Usage: check-binaries.sh APP KEYBOARD ACTIVITY" >&2; exit 2; }
app=$1 keyboard=$2 activity=$3
failures=0

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

# URLSession and every type named after it, the other URL loading and Network framework types, sockets and name
# lookup, and web views: what ../scripts/check-rules.py keeps out of the package's sources, as the linker sees it.
network_symbols='URLSession|NSURLConnection|NSURLDownload|NWConnection|NWListener|NWBrowser|NWEndpoint|_nw_[a-z]|CFSocket|CFStreamCreatePairWithSocket|CFHost|WKWebView|^_(socket|connect|getaddrinfo|gethostbyname|gethostbyname2)$'
network_libraries='/(CFNetwork|Network|WebKit)\.framework/|/libnetwork\.'
# A Swift symbol of a module carries the module's name with its length in front of it.
speech_and_dictionary='12SpeechEngine|13DictionaryKit|13DictationCore'
shared_modules="$speech_and_dictionary|9TextRules"

for binary in "$app" "$keyboard" "$activity"; do
    name=$(basename "$binary")
    if [ ! -f "$binary" ]; then
        fail "$name is missing"
        continue
    fi
    if ! symbols=$(xcrun nm -u "$binary" 2>/dev/null); then
        fail "$name: cannot read its symbols"
        continue
    fi
    found=$(printf '%s\n' "$symbols" | grep -E "$network_symbols" | head -3 | tr '\n' ' ')
    [ -z "$found" ] || fail "$name names a networking API: $found"
    if ! libraries=$(xcrun otool -L "$binary" 2>/dev/null); then
        fail "$name: cannot read the libraries it links"
        continue
    fi
    found=$(printf '%s\n' "$libraries" | grep -E "$network_libraries" | head -3 | tr -d '\t' | tr '\n' ' ')
    [ -z "$found" ] || fail "$name links a networking library: $found"
done

# $1: executable, $2: the modules it must hold nothing of, $3: what they are.
holds_none() {
    [ -f "$1" ] || return 0
    found=$(xcrun nm "$1" 2>/dev/null | grep -E "$2" | head -3 | awk '{ print $NF }' | tr '\n' ' ')
    [ -z "$found" ] || fail "$(basename "$1") holds $3: $found"
}
holds_none "$keyboard" "$speech_and_dictionary" "speech or dictionary code"
holds_none "$activity" "$shared_modules" "code of the shared modules"

if [ "$failures" -gt 0 ]; then
    echo "$failures binary check(s) failed."
    exit 1
fi
echo "Binary checks passed: no networking API; the keyboard and the Live Activity hold only what they may."
