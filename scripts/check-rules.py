#!/usr/bin/env python3
"""A lint for the rules a compiler cannot check (ARCHITECTURE.md, sections 2 and 9).

It catches the obvious mistakes and fails with the offending lines. It does not prove the invariants; review does.
Rules that look for API use read Swift code only: comments and the text of string literals and `#/.../#` regex
literals are ignored, while code inside a string's interpolation is still read.

A bare slash is ambiguous without a Swift parser: `/.../` may be a regex literal or two divisions. Where a slash
might open a regex literal the source is therefore read both ways, and a violation in either reading counts. So a
misjudged slash can never hide a banned call. The price is that a banned name written inside a bare regex literal
is reported; write that literal as `#/.../#`, which is unambiguous, to have its text ignored.

Runs on Python 3.9 or later, on macOS and Linux.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRING_OPEN = re.compile(r'(#*)("""|")')
EXTENDED_REGEX_OPEN = re.compile(r"(#+)/")
# What a bare regex literal may follow: an opening bracket, a separator, an assignment or comparison, or one of
# these words. After a name, a number or a closing bracket a slash is division.
REGEX_AFTER = set("([{,;:=?")
REGEX_AFTER_WORDS = ("return", "in", "case", "else", "try", "await", "throw", "if", "guard", "while", "where",
                     "switch", "yield")


def code_only(src, bare_regex=True):
    """`src` with comments and literal text replaced by spaces. Line breaks, and so line numbers, are kept.

    With `bare_regex` a slash in a position where a regex literal may start, and with a closing slash on its line,
    is read as one; without it every bare slash is division.
    """
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

    def bare_regex_end(i):
        """The index just past the bare regex literal whose opening slash is at `i`, or None if it is not one."""
        if not bare_regex or i + 1 >= n or src[i + 1] in " \t\n":
            return None
        k = i - 1
        while k >= 0 and out[k] in " \t":
            k -= 1
        if k >= 0 and out[k] != "\n" and out[k] not in REGEX_AFTER:
            m = k
            while m >= 0 and (out[m].isalnum() or out[m] == "_"):
                m -= 1
            if "".join(out[m + 1:k + 1]) not in REGEX_AFTER_WORDS:
                return None
        j, classes, groups = i + 1, 0, 0
        while j < n and src[j] != "\n":
            c = src[j]
            if c == "\\":
                if j + 1 < n and src[j + 1] == "\n":
                    return None
                j += 2
                continue
            if classes:
                classes += (c == "[") - (c == "]")
            elif c == "[":
                classes = 1
            elif c == "(":
                groups += 1
            elif c == ")":
                # As Swift does: a closing parenthesis with no opening one means this was an operator, as in
                # `reduce(1, /)`, not the start of a regex.
                if groups == 0:
                    return None
                groups -= 1
            elif c == "/":
                return j + 1
            j += 1
        return None

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
            elif src[i] == "/":
                end = bare_regex_end(i)
                if end is None:
                    i += 1
                else:
                    blank(i + 1, end - 1)
                    i = end
            elif src[i] == "#" and EXTENDED_REGEX_OPEN.match(src, i):
                opener = EXTENDED_REGEX_OPEN.match(src, i)
                closer = "/" + opener.group(1)
                end = opener.end()
                # The first closing delimiter that is not escaped: `\/#` inside the pattern is text.
                while end < n and not src.startswith(closer, end):
                    end += 2 if src[end] == "\\" else 1
                end = min(end, n)
                blank(opener.end(), end)
                i = end + len(closer)
            elif src[i] == '"' or (src[i] == "#" and STRING_OPEN.match(src, i)):
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


# An import declaration, wherever it starts: at the start of a line or after a semicolon, with its tokens on one
# line or several.
IMPORT = re.compile(
    r"(?:^|;)[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+"
    r"(?:(?:struct|class|enum|protocol|typealias|func|let|var)\s+)?([A-Za-z_]\w*)", re.MULTILINE)
NETWORK = re.compile(r"\b(URLSession|NWConnection|NWListener|NWBrowser|CFNetwork|WKWebView|CFSocketCreate|getaddrinfo)\b")
LOG_CALLS = r"(?:print|debugPrint|dump|NSLog|os_log)\s*\("
LOGGING = re.compile(
    r"(?<![\w.])" + LOG_CALLS + r"|\b(?:Swift|Foundation|os|OSLog)\s*\.\s*" + LOG_CALLS + r"|\b(?:Logger|OSLog)\s*\(")
UNCHECKED = re.compile(r"@unchecked\s+Sendable")
OLD_NAMES = re.compile(r"localflow|freeflow|wilderness", re.IGNORECASE)
WEIGHTS = re.compile(r"\.(mlmodelc|mlpackage|f32bin|f16bin|safetensors|wav|caf|m4a|dmg)(/|$)")

UI_AND_MODEL = {"AppKit", "SwiftUI", "UIKit", "Cocoa", "AVFoundation", "AVFAudio", "CoreML"}
PURE = ("DictationCore", "TextRules", "DesignCore", "DictionaryKit")
NEUTRAL = {"SpeechEngine": {"AppKit", "SwiftUI", "UIKit", "Cocoa"}, "Persistence": {"AppKit", "SwiftUI", "UIKit", "Cocoa"}}
MAY_PRINT = ("SorelloSnapshots", "SorelloTranscribe")


def lint_swift(module, name, src):
    """The (rule, line number, line) violations in one Swift source of `module`."""
    raw = src.split("\n")
    # Both readings of any ambiguous slash; a violation in either counts.
    readings = {code_only(src, True), code_only(src, False)}
    found = set()
    for code in readings:
        for imported in IMPORT.finditer(code):
            framework = imported.group(1)
            number = code.count("\n", 0, imported.start(1)) + 1
            text = raw[number - 1].strip()
            if framework == "Network":
                found.add(("Sorello makes no network connections", number, text))
            if module in PURE and framework in UI_AND_MODEL:
                found.add(("pure modules import only Foundation", number, text))
            if framework in NEUTRAL.get(module, ()):
                found.add(("neutral modules must also build for iOS", number, text))

        for number, line in enumerate(code.split("\n"), 1):
            text = raw[number - 1].strip()
            if NETWORK.search(line):
                found.add(("Sorello makes no network connections", number, text))
            if LOGGING.search(line) and module not in MAY_PRINT and name != "Diagnostics.swift":
                found.add(("log only through Diagnostics, which cannot carry content", number, text))
            if UNCHECKED.search(line) and not any("Safe:" in near for near in raw[max(0, number - 4):number + 3]):
                found.add(("@unchecked Sendable needs a '// Safe:' comment naming the lock or queue", number, text))
    return sorted(found, key=lambda violation: (violation[1], violation[0]))


def self_test():
    def rules(module, src, name="File.swift"):
        return sorted({rule.split(" ")[0] for rule, _, _ in lint_swift(module, name, src)})

    cases = [
        # (module, source, the first word of each rule that should fire[, file name])
        ("SorelloApp", 'print("x")', ["log"]),
        ("SorelloApp", 'Swift.print("x")', ["log"]),
        ("SorelloApp", 'print ("x")', ["log"]),
        ("SorelloApp", 'Foundation.NSLog("x")', ["log"]),
        ("SorelloApp", 'os.os_log("x")', ["log"]),
        ("SorelloApp", 'let l = Logger(subsystem: "s", category: "c")', ["log"]),
        ("SorelloApp", 'let l = os.Logger(subsystem: "s", category: "c")', ["log"]),
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
        # `#/.../#` regex literals are text, escaped delimiters included, and a quote inside one starts no string.
        ("TextRules", "let pattern = #/URLSession/#", []),
        ("TextRules", "let found = text.firstMatch(of: #/[/]print(1)/#)", []),
        ("TextRules", "let pattern = #/abc\\/#URLSession/#", []),
        ("TextRules", "let pattern = ##/a/#print(1)/##", []),
        ("TextRules", "let pattern = #/\n  print(1)  # the call\n  URLSession\n/#\nlet x = 1", []),
        ("TextRules", 'let pattern = #/abc\\/#"def/#; print("x")', ["log"]),
        ("TextRules", 'let r = value.replacing(#/"/#, with: { _ in Swift.print("x"); return "y" })', ["log"]),
        # A bare slash is read both ways, so neither a regex's quote nor a division can hide a call.
        ("TextRules", r"let pattern = /print\(x\)/", []),
        ("TextRules", 'let m = text.firstMatch(of: /"/); print("x")', ["log"]),
        ("TextRules", "let ratio = total / count; print(ratio)", ["log"]),
        ("TextRules", "let ratio = (a + b) / 2 / print(c)", ["log"]),
        ("TextRules", "let ratio = values.reduce(1, /); print(ratio / 2)", ["log"]),
        ("TextRules", "let ratio = values.reduce(1, /); print(ratio) // Explain the ratio.", ["log"]),
        ("TextRules", "let ops = [+, -, *, /]; print(x/y)", ["log"]),
        ("TextRules", "let half = a!/2; print(b!/2)", ["log"]),
        ("TextRules", "let f: (Double, Double) -> Double = (/); print(f(a, b)/2)", ["log"]),
        ("TextRules", "let x = a / b / c", []),
        # The price of reading both ways: a banned name in a bare regex is reported. `#/.../#` is the way out.
        ("TextRules", "let pattern = /URLSession/", ["Sorello"]),
        # Imports, however they are laid out.
        ("SorelloApp", "import Network", ["Sorello"]),
        ("SorelloApp", "    @preconcurrency import Network", ["Sorello"]),
        ("SorelloApp", "import Foundation; import Network", ["Sorello"]),
        ("DesignCore", "import AppKit", ["pure"]),
        ("DesignCore", "  #if os(macOS)\n    import AppKit\n  #endif", ["pure"]),
        ("DesignCore", "public import SwiftUI", ["pure"]),
        ("DesignCore", "@preconcurrency import AVFoundation", ["pure"]),
        ("DesignCore", "import struct AppKit.NSColor", ["pure"]),
        ("DesignCore", "import Foundation; import AppKit", ["pure"]),
        ("DesignCore", "import\nAppKit", ["pure"]),
        ("DesignCore", "import Foundation\nimport CoreGraphics", []),
        ("DesignCore", "// import AppKit would break the iOS build", []),
        ("DesignCore", 'let s = "import AppKit"', []),
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
    # A violation is reported on the line it is on.
    numbered = lint_swift("DesignCore", "File.swift", "import Foundation\n\nimport\n  AppKit\n")
    if [number for _, number, _ in numbered] != [4]:
        failures += 1
        print("check-rules self-test: wrong line for a split import: %r" % (numbered,), file=sys.stderr)
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
