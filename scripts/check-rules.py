#!/usr/bin/env python3
"""A lint for the rules a compiler cannot check (ARCHITECTURE.md, sections 2 and 9).

It catches the obvious mistakes and fails with the offending lines. It does not prove the invariants; review does.
Rules that look for API use read Swift code only: comments and the text of string literals are ignored, while code
inside a string's interpolation is still read. Runs on Python 3.9 or later, on macOS and Linux.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRING_OPEN = re.compile(r'(#*)("""|")')


def code_only(src):
    """`src` with comments and string-literal text replaced by spaces. Line breaks, and so line numbers, are kept."""
    out = list(src)
    n = len(src)

    def blank(a, b):
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    def scan_string(i):
        match = STRING_OPEN.match(src, i)
        hashes, quote = match.group(1), match.group(2)
        closer, escape = quote + hashes, "\\" + hashes
        start = j = match.end()
        while j < n:
            if src.startswith(escape, j):
                k = j + len(escape)
                if k < n and src[k] == "(":
                    blank(start, j)
                    j = start = scan_code(k + 1, True)
                else:
                    j = k + 1
            elif src.startswith(closer, j):
                blank(start, j)
                return j + len(closer)
            elif quote == '"' and src[j] == "\n":
                break
            else:
                j += 1
        blank(start, j)
        return j

    def scan_code(i, interpolation):
        depth = 0
        while i < n:
            if src.startswith("//", i):
                end = src.find("\n", i)
                end = n if end < 0 else end
                blank(i, end)
                i = end
            elif src.startswith("/*", i):
                j, level = i + 2, 1
                while j < n and level:
                    if src.startswith("/*", j):
                        level, j = level + 1, j + 2
                    elif src.startswith("*/", j):
                        level, j = level - 1, j + 2
                    else:
                        j += 1
                blank(i, j)
                i = j
            elif src[i] == '"' or (src[i] == "#" and STRING_OPEN.match(src, i) and STRING_OPEN.match(src, i).group(1)):
                i = scan_string(i)
            elif interpolation and src[i] == "(":
                depth, i = depth + 1, i + 1
            elif interpolation and src[i] == ")":
                if depth == 0:
                    return i + 1
                depth, i = depth - 1, i + 1
            else:
                i += 1
        return n

    scan_code(0, False)
    return "".join(out)


IMPORT = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+"
    r"(?:(?:struct|class|enum|protocol|typealias|func|let|var)\s+)?([A-Za-z_]\w*)")
NETWORK = re.compile(r"\b(URLSession|NWConnection|NWListener|NWBrowser|CFNetwork|WKWebView|CFSocketCreate|getaddrinfo)\b")
LOGGING = re.compile(
    r"(?<![\w.])(?:print|debugPrint|dump|NSLog|os_log)\s*\(|\bSwift\s*\.\s*(?:print|debugPrint|dump)\s*\(|\b(?:Logger|OSLog)\s*\(")
UNCHECKED = re.compile(r"@unchecked\s+Sendable")
OLD_NAMES = re.compile(r"localflow|freeflow|wilderness", re.IGNORECASE)
WEIGHTS = re.compile(r"\.(mlmodelc|mlpackage|f32bin|f16bin|safetensors|wav|caf|m4a|dmg)(/|$)")

UI_AND_MODEL = {"AppKit", "SwiftUI", "UIKit", "Cocoa", "AVFoundation", "AVFAudio", "CoreML"}
PURE = ("DictationCore", "TextRules", "DesignCore", "DictionaryKit")
NEUTRAL = {"SpeechEngine": {"AppKit", "SwiftUI", "UIKit", "Cocoa"}, "Persistence": {"AppKit", "SwiftUI", "UIKit", "Cocoa"}}
MAY_PRINT = ("SorelloSnapshots", "SorelloTranscribe")


def lint_swift(module, name, src):
    """The (rule, line number, line) violations in one Swift source of `module`."""
    found = []
    raw = src.split("\n")
    code = code_only(src).split("\n")
    for number, line in enumerate(code, 1):
        text = raw[number - 1].strip()
        if NETWORK.search(line):
            found.append(("Sorello makes no network connections", number, text))
        imported = IMPORT.match(line)
        if imported:
            framework = imported.group(1)
            if framework == "Network":
                found.append(("Sorello makes no network connections", number, text))
            if module in PURE and framework in UI_AND_MODEL:
                found.append(("pure modules import only Foundation", number, text))
            if framework in NEUTRAL.get(module, ()):
                found.append(("neutral modules must also build for iOS", number, text))
        if LOGGING.search(line) and module not in MAY_PRINT and name != "Diagnostics.swift":
            found.append(("log only through Diagnostics, which cannot carry content", number, text))
        if UNCHECKED.search(line) and not any("Safe:" in near for near in raw[max(0, number - 4):number + 3]):
            found.append(("@unchecked Sendable needs a '// Safe:' comment naming the lock or queue", number, text))
    return found


def self_test():
    def rules(module, src, name="File.swift"):
        return sorted({rule.split(" ")[0] for rule, _, _ in lint_swift(module, name, src)})

    cases = [
        # (module, source, expected first words of the rules that fire)
        ("SorelloApp", 'print("x")', ["log"]),
        ("SorelloApp", 'Swift.print("x")', ["log"]),
        ("SorelloApp", 'print ("x")', ["log"]),
        ("SorelloApp", 'let l = Logger(subsystem: "s", category: "c")', ["log"]),
        ("SorelloApp", 'let s = "\\(print("x"))"', ["log"]),
        ("SorelloApp", "/// Do not call print() here; use Diagnostics.", []),
        ("SorelloApp", 'let s = "print(x) and URLSession"', []),
        ("SorelloApp", "/* print(1) /* nested URLSession */ still a comment */ let x = 1", []),
        ("SorelloApp", 'let s = #"a "quoted" print(1)"#', []),
        ("SorelloApp", 'let s = """\nprint(1)\nURLSession\n"""', []),
        ("SorelloApp", "printer.print(page)", []),
        ("SorelloApp", "fingerprint(of: x)", []),
        ("SorelloTranscribe", 'print("x")', []),
        ("DictationCore", 'print("x")', [], "Diagnostics.swift"),
        ("SorelloApp", "let s = URLSession.shared", ["Sorello"]),
        ("SorelloApp", "// URLSession is forbidden in this application.", []),
        ("SorelloApp", "import Network", ["Sorello"]),
        ("SorelloApp", "    @preconcurrency import Network", ["Sorello"]),
        ("DesignCore", "import AppKit", ["pure"]),
        ("DesignCore", "  #if os(macOS)\n    import AppKit\n  #endif", ["pure"]),
        ("DesignCore", "public import SwiftUI", ["pure"]),
        ("DesignCore", "@preconcurrency import AVFoundation", ["pure"]),
        ("DesignCore", "import struct AppKit.NSColor", ["pure"]),
        ("DesignCore", "import Foundation\nimport CoreGraphics", []),
        ("DesignCore", "// import AppKit would break the iOS build", []),
        ("SpeechEngine", "import CoreML\nimport Accelerate", []),
        ("SpeechEngine", "import AppKit", ["neutral"]),
        ("MacPlatform", "import AppKit", []),
        ("SorelloApp", "final class A: @unchecked Sendable {}", ["@unchecked"]),
        ("SorelloApp", "// Safe: guarded by `lock`.\nfinal class A: @unchecked Sendable {}", []),
    ]
    failures = 0
    for case in cases:
        module, src, expected = case[0], case[1], case[2]
        name = case[3] if len(case) > 3 else "File.swift"
        got = rules(module, src, name)
        if got != expected:
            failures += 1
            print("check-rules self-test: %r in %s gave %s, expected %s" % (src, module, got, expected), file=sys.stderr)
    return failures


def main():
    if "--self-test" in sys.argv:
        return 1 if self_test() else 0

    problems = {}

    def report(rule, where):
        problems.setdefault(rule, []).append(where)

    sources = os.path.join(ROOT, "Sources")
    for directory, _, files in sorted(os.walk(sources)):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, ROOT)
            module = os.path.relpath(path, sources).split(os.sep)[0]
            with open(path, encoding="utf-8") as handle:
                src = handle.read()
            for rule, number, text in lint_swift(module, name, src):
                report(rule, "%s:%d: %s" % (relative, number, text))

    # The old names are gone, comments included.
    for top in ("Sources", "Config", "scripts", "Makefile"):
        start = os.path.join(ROOT, top)
        paths = [start] if os.path.isfile(start) else [
            os.path.join(directory, name) for directory, _, files in sorted(os.walk(start)) for name in sorted(files)]
        for path in paths:
            if os.path.basename(path) == "check-rules.py":
                continue
            try:
                with open(path, encoding="utf-8") as handle:
                    lines = handle.read().split("\n")
            except (UnicodeDecodeError, OSError):
                continue
            for number, line in enumerate(lines, 1):
                if OLD_NAMES.search(line):
                    report("an earlier product's name is still in the code",
                           "%s:%d: %s" % (os.path.relpath(path, ROOT), number, line.strip()))

    # No model weights, audio or build output in Git.
    inside = subprocess.run(["git", "-C", ROOT, "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
    if inside.returncode == 0:
        tracked = subprocess.run(["git", "-C", ROOT, "ls-files"], capture_output=True, text=True).stdout.split("\n")
        for path in tracked:
            if WEIGHTS.search(path):
                report("weights, audio and disk images stay out of Git", path)

    for rule, places in problems.items():
        print("check-rules: " + rule, file=sys.stderr)
        for place in places:
            print("    " + place, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
