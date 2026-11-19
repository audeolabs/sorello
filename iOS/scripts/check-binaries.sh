#!/bin/sh
# Checks what the app's three executables link (ARCHITECTURE.md, "Privacy and security invariants", and
# ../ARCHITECTURE.md, section 13):
# - none of them names a networking API, as an undefined symbol or as a linked library: the iPhone app opens no
#   network connection and holds no networking code;
# - the keyboard holds nothing of SpeechEngine or DictationCore, so it cannot reach the model (it links DictionaryKit
#   for the rules that notice a correction, and has no dictionary to read), and the Live Activity nothing of any
#   shared module;
# - neither the keyboard nor the Live Activity holds anything of NotesCore, so neither can seal or open a note.
# With --keyboard-dictation, the executables of an experiment build (KEYBOARD_DICTATION=1; ARCHITECTURE.md,
# "In-keyboard dictation (experiment)"): the keyboard may hold SpeechEngine and DictationCore, link WebKit, and name
# WKWebView and its configuration, delegate, message and data store types; nothing else is loosened. Without it, the
# keyboard names no WebKit type at all.
# It reads the executables only. Prints every failure and exits 1 if there is any.
#
# Usage: check-binaries.sh [--keyboard-dictation] APP KEYBOARD ACTIVITY   (the three executables)
set -u

experiment=
if [ "${1:-}" = --keyboard-dictation ]; then
    experiment=yes
    shift
fi
[ $# -eq 3 ] || { echo "Usage: check-binaries.sh [--keyboard-dictation] APP KEYBOARD ACTIVITY" >&2; exit 2; }
app=$1 keyboard=$2 activity=$3
failures=0

fail() {
    echo "FAIL: $*"
    failures=$((failures + 1))
}

xcrun --find swift-demangle > /dev/null 2>&1 || fail "swift-demangle is missing: the keyboard's WebKit types cannot be read"

# URLSession and every type named after it, the other URL loading and Network framework types, sockets and name
# lookup, and web views: what ../scripts/check-rules.py keeps out of the package's sources, as the linker sees it.
network_symbols='URLSession|NSURLConnection|NSURLDownload|NWConnection|NWListener|NWBrowser|NWEndpoint|_nw_[a-z]|CFSocket|CFStreamCreatePairWithSocket|CFHost|WKWebView|^_(socket|connect|getaddrinfo|gethostbyname|gethostbyname2)$'
network_libraries='/(CFNetwork|Network|WebKit)\.framework/|/libnetwork\.'
# The experiment's keyboard: the same, but for its one web view.
experiment_network_symbols='URLSession|NSURLConnection|NSURLDownload|NWConnection|NWListener|NWBrowser|NWEndpoint|_nw_[a-z]|CFSocket|CFStreamCreatePairWithSocket|CFHost|^_(socket|connect|getaddrinfo|gethostbyname|gethostbyname2)$'
experiment_network_libraries='/(CFNetwork|Network)\.framework/|/libnetwork\.'
# The WebKit types the experiment's keyboard may name: the web view (and its capture state), its configuration, its
# navigation and UI delegates with what they are handed, the script message handler and its message, and the data store.
web_view_types='WKWebView|WKWebViewConfiguration|WKPreferences|WKWebpagePreferences|WKAudiovisualMediaTypes|WKUserContentController|WKScriptMessage|WKScriptMessageHandler|WKNavigationDelegate|WKUIDelegate|WKNavigation|WKNavigationAction|WKNavigationActionPolicy|WKNavigationResponse|WKNavigationResponsePolicy|WKNavigationType|WKFrameInfo|WKSecurityOrigin|WKMediaCaptureType|WKMediaCaptureState|WKPermissionDecision|WKWindowFeatures|WKWebsiteDataStore'
# A Swift symbol of a module carries the module's name with its length in front of it.
speech='12SpeechEngine|13DictationCore'
shared_modules="$speech|13DictionaryKit|9TextRules"
# Every NotesCore type is named Note… (ARCHITECTURE.md, "Notes"), so any of them, in any module, shows as a length
# followed by Note and a capital (the rest of its name, or the kind of a type named Note). NotesCore seals with
# CryptoKit's HPKE, which nothing else in the app uses.
notes='[0-9]Note[A-Z]|9CryptoKit4HPKE'

for binary in "$app" "$keyboard" "$activity"; do
    name=$(basename "$binary")
    if [ ! -f "$binary" ]; then
        fail "$name is missing"
        continue
    fi
    symbols_pattern=$network_symbols libraries_pattern=$network_libraries
    if [ -n "$experiment" ] && [ "$binary" = "$keyboard" ]; then
        symbols_pattern=$experiment_network_symbols libraries_pattern=$experiment_network_libraries
    fi
    if ! symbols=$(xcrun nm -u "$binary" 2>/dev/null); then
        fail "$name: cannot read its symbols"
        continue
    fi
    found=$(printf '%s\n' "$symbols" | grep -E "$symbols_pattern" | head -3 | tr '\n' ' ')
    [ -z "$found" ] || fail "$name names a networking API: $found"
    if [ "$binary" = "$keyboard" ]; then
        # Every WebKit type the keyboard names, as an Objective-C class or inside a Swift symbol (demangled, so a
        # name is whole).
        if ! demangled=$(printf '%s\n' "$symbols" | xcrun swift-demangle 2>/dev/null); then
            fail "$name: cannot demangle its symbols"
            continue
        fi
        web_types=$(printf '%s\n' "$demangled" | grep -oE '(^|[^A-Za-z0-9])WK[A-Z][A-Za-z0-9]*' | sed 's/^[^W]*//' | sort -u)
        if [ -n "$experiment" ]; then
            found=$(printf '%s\n' "$web_types" | grep -vxE "$web_view_types" | grep . | head -3 | tr '\n' ' ')
            [ -z "$found" ] || fail "$name names WebKit types beyond its web view's: $found"
        else
            found=$(printf '%s\n' "$web_types" | grep . | head -3 | tr '\n' ' ')
            [ -z "$found" ] || fail "$name names WebKit types: $found"
        fi
    fi
    if ! libraries=$(xcrun otool -L "$binary" 2>/dev/null); then
        fail "$name: cannot read the libraries it links"
        continue
    fi
    found=$(printf '%s\n' "$libraries" | grep -E "$libraries_pattern" | head -3 | tr -d '\t' | tr '\n' ' ')
    [ -z "$found" ] || fail "$name links a networking library: $found"
done

# $1: executable, $2: the modules it must hold nothing of, $3: what they are.
holds_none() {
    [ -f "$1" ] || return 0
    if ! all_symbols=$(xcrun nm "$1" 2>/dev/null); then
        fail "$(basename "$1"): cannot read its symbols"
        return 0
    fi
    found=$(printf '%s\n' "$all_symbols" | grep -E "$2" | head -3 | awk '{ print $NF }' | tr '\n' ' ')
    [ -z "$found" ] || fail "$(basename "$1") holds $3: $found"
}
[ -n "$experiment" ] || holds_none "$keyboard" "$speech" "speech code"
holds_none "$activity" "$shared_modules" "code of the shared modules"
holds_none "$keyboard" "$notes" "notes code"
holds_none "$activity" "$notes" "notes code"

if [ "$failures" -gt 0 ]; then
    echo "$failures binary check(s) failed."
    exit 1
fi
if [ -n "$experiment" ]; then
    echo "Binary checks passed (keyboard dictation experiment): no networking API but the keyboard's web view; the keyboard and the Live Activity hold only what they may."
else
    echo "Binary checks passed: no networking API; the keyboard and the Live Activity hold only what they may."
fi
