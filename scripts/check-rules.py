#!/usr/bin/env python3
"""A lint for the rules a compiler cannot check (ARCHITECTURE.md, sections 2 and 9).

It catches the obvious mistakes and fails with the offending lines. It does not prove the invariants; review does.
Rules that look for API use read Swift code only: comments and the text of string and regex literals are ignored,
while code inside a string's interpolation is still read.

A bare `/.../` regex literal cannot be told from two divisions without a Swift parser, so it is found the way the
compiler finds it, as nearly as a scanner can: a slash where an expression may start, not followed by a space,
with its closing slash on the same line and no closing parenthesis left unopened. Its text is then ignored when
reading the code after it, so a quote inside it starts no string. But because that judgement can be wrong, the
text between the two slashes is also searched for the banned names. A banned name written inside a bare regex
literal is therefore reported; write that literal as `#/.../#`, which is unambiguous, to have its text ignored.

Runs on Python 3.9 or later, on macOS and Linux.
"""
import bisect
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRING_OPEN = re.compile(r'(#*)("""|")')
EXTENDED_REGEX_OPEN = re.compile(r"(#+)/")
# A bare regex literal starts where an expression may start: at the start of a line, after an opening bracket, a
# separator or an operator, or after one of these words. After anything else (a name, a number, a closing bracket,
# the end of a literal, a postfix `!` or `?`, or a character this scanner does not know) a slash is division.
OPENS_EXPRESSION = set("([{,;:=+-*%<>&|^~")
BEFORE_EXPRESSION = ("return", "in", "case", "else", "try", "await", "throw", "if", "guard", "while", "where",
                     "switch", "yield", "do", "repeat", "is", "as")


def is_name_character(character):
    """Whether `character` can be part of a Swift name. Every character outside ASCII counts: Swift allows
    most of them in names, combining marks included, and taking one for a name is the safe mistake."""
    return character == "_" or character.isalnum() or ord(character) > 0x7F


def scan(src):
    """`src` with comments and literal text replaced by spaces, and the bare regex literals found in it.

    Line breaks, and so line numbers, are kept in the first. The second is a list of (offset of the opening
    slash, the text between the slashes).
    """
    out = list(src)
    n = len(src)
    bare = []

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

    def keyword_ending_at(k):
        """The word that ends at `k` if it is one of `BEFORE_EXPRESSION` used as a keyword, else an empty string.
        After a dot the word is a member's name (`schedule.repeat`), which ends an expression like any name."""
        m = k
        while m >= 0 and is_name_character(out[m]):
            m -= 1
        word = "".join(out[m + 1:k + 1])
        while m >= 0 and out[m] in " \t\n":
            m -= 1
        if word not in BEFORE_EXPRESSION or (m >= 0 and out[m] == "."):
            return ""
        return word

    def may_start_expression(i):
        """Whether an expression may start at `i`, judged by what comes before it on the line."""
        k = i - 1
        while k >= 0 and out[k] in " \t":
            k -= 1
        if k < 0 or out[k] == "\n":
            return True
        if out[k] in "!?":
            # Attached to what it follows, it is a postfix operator and ends an expression: `a!/2`, `b?.c`.
            # After `try` it does not: `try? /x/`. Standing alone it is an operator: `a ? /x/ : /y/`, `a ?? /x/`.
            r = k
            while r >= 0 and out[r] in "!?":
                r -= 1
            if r < 0 or out[r] in " \t\n":
                return True
            return keyword_ending_at(r) == "try"
        if is_name_character(out[k]):
            return keyword_ending_at(k) != ""
        return out[k] in OPENS_EXPRESSION

    def bare_regex_end(i):
        """The index just past the bare regex literal whose opening slash is at `i`, or None if it is not one."""
        if i + 1 >= n or src[i + 1] in " \t\n" or not may_start_expression(i):
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
                    bare.append((i, src[i + 1:end - 1]))
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
    return "".join(out), bare


def code_only(src):
    """`src` with comments and literal text replaced by spaces."""
    return scan(src)[0]


# An import declaration, wherever it starts: at the start of a line or after a semicolon, with its tokens on one
# line or several.
IMPORT = re.compile(
    r"(?:^|;)[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)?import\s+"
    r"(?:(?:struct|class|enum|protocol|typealias|func|let|var)\s+)?([A-Za-z_]\w*)", re.MULTILINE)
# URLSession and every type named after it (its configuration, its delegates) are allowed in one file, the model's
# download (ARCHITECTURE.md, section 9, invariant 1). The rest are allowed nowhere.
SESSION = re.compile(r"\b(?:NS)?URLSession\w*")
SESSION_FILE = "Sources/SpeechEngine/ModelDownloader.swift"
NETWORK = re.compile(r"\b(NSURLConnection|NWConnection|NWListener|NWBrowser|CFNetwork|WKWebView|CFSocketCreate|getaddrinfo)\b")
# The model's host is in Models/model.lock.json and nowhere in the sources, comments and strings included. The words
# a user reads, "Hugging Face", are two words and do not match.
HOST = re.compile(r"huggingface|(?<![\w-])hf\.co\b", re.IGNORECASE)
LOG_CALLS = r"(?:print|debugPrint|dump|NSLog|os_log)\s*\("
LOGGING = re.compile(
    r"(?<![\w.])" + LOG_CALLS + r"|\b(?:Swift|Foundation|os|OSLog)\s*\.\s*" + LOG_CALLS + r"|\b(?:Logger|OSLog)\s*\(")
# Sparkle, the app's updater, is reached through the `Updating` protocol; one file imports it (ARCHITECTURE.md,
# section 2), and no test does, so no test can start it.
SPARKLE_FILE = "Sources/SorelloApp/Adapters/SparkleUpdater.swift"
SPARKLE_RULE = "only %s imports Sparkle" % SPARKLE_FILE
UNCHECKED = re.compile(r"@unchecked\s+Sendable")
OLD_NAMES = re.compile(r"localflow|freeflow|wilderness", re.IGNORECASE)
WEIGHTS = re.compile(r"\.(mlmodelc|mlpackage|f32bin|f16bin|safetensors|wav|caf|m4a|dmg)(/|$)")

UI_AND_MODEL = {"AppKit", "SwiftUI", "UIKit", "Cocoa", "AVFoundation", "AVFAudio", "CoreML"}
PURE = ("DictationCore", "TextRules", "DesignCore", "DictionaryKit")
NEUTRAL = {"SpeechEngine": {"AppKit", "SwiftUI", "UIKit", "Cocoa"}, "Persistence": {"AppKit", "SwiftUI", "UIKit", "Cocoa"}}
# Transcribing a file goes through the engine, which reads the file; this module adds rules and progress to it, and
# imports no framework that draws or decodes (ARCHITECTURE.md, section 5, "Transcribing a file").
THROUGH_ENGINE = ("FileTranscription",)
# The command-line tools write to the person who ran them (ARCHITECTURE.md, section 9, invariant 2): the `sorello`
# command writes a file's text to standard output and its messages to standard error, and keeps no log.
MAY_PRINT = ("SorelloSnapshots", "SorelloTranscribe", "SorelloCommand", "SorelloCommandMain")


def lint_swift(path, src):
    """The (rule, line number, line) violations in the Swift source at `path`, relative to the repository."""
    module = path.split("/")[1] if path.startswith("Sources/") else ""
    name = os.path.basename(path)
    raw = src.split("\n")
    code, bare = scan(src)
    may_log = module in MAY_PRINT or name == "Diagnostics.swift"
    may_connect = path == SESSION_FILE

    def connects(text):
        return NETWORK.search(text) or (SESSION.search(text) and not may_connect)
    found = set()

    for imported in IMPORT.finditer(code):
        framework = imported.group(1)
        number = code.count("\n", 0, imported.start(1)) + 1
        text = raw[number - 1].strip()
        if framework == "Sparkle" and path != SPARKLE_FILE:
            found.add((SPARKLE_RULE, number, text))
        if framework == "Network":
            found.add(("only the model's download opens a connection, through URLSession", number, text))
        if module in PURE and framework in UI_AND_MODEL:
            found.add(("pure modules import only Foundation", number, text))
        if framework in NEUTRAL.get(module, ()):
            found.add(("neutral modules must also build for iOS", number, text))
        if module in THROUGH_ENGINE and framework in UI_AND_MODEL:
            found.add(("FileTranscription reads files only through the engine, and draws nothing", number, text))

    for number, line in enumerate(code.split("\n"), 1):
        text = raw[number - 1].strip()
        if connects(line):
            found.add(("only the model's download opens a connection, through URLSession", number, text))
        if LOGGING.search(line) and not may_log:
            found.add(("log only through Diagnostics, which cannot carry content", number, text))
        if UNCHECKED.search(line) and not any("Safe:" in near for near in raw[max(0, number - 4):number + 3]):
            found.add(("@unchecked Sendable needs a '// Safe:' comment naming the lock or queue", number, text))

    # What was taken for a bare regex literal may have been code after all, so its text is searched too.
    line_starts = [0] + [index + 1 for index, character in enumerate(src) if character == "\n"]
    for offset, body in bare:
        number = bisect.bisect_right(line_starts, offset)
        text = raw[number - 1].strip()
        if connects(body):
            found.add(("only the model's download opens a connection, through URLSession", number, text))
        if LOGGING.search(body) and not may_log:
            found.add(("log only through Diagnostics, which cannot carry content", number, text))
    return sorted(found, key=lambda violation: (violation[1], violation[0]))


def lint_test(path, src):
    """The violations in the test source at `path`: tests are read only for an import of Sparkle."""
    return [violation for violation in lint_swift(path, src) if violation[0] == SPARKLE_RULE]


def self_test():
    def rules(module, src, name="File.swift"):
        return sorted({rule.split(" ")[0] for rule, _, _ in lint_swift("Sources/%s/%s" % (module, name), src)})

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
        ("SorelloCommand", 'print("x")', []),
        ("SorelloCommandMain", 'FileHandle.standardError.write(d); print("x")', []),
        ("FileTranscription", 'print("x")', ["log"]),
        ("DictationCore", 'print("x")', [], "Diagnostics.swift"),
        ("SorelloApp", "let s = URLSession.shared", ["only"]),
        ("SorelloApp", "// URLSession is forbidden in this application.", []),
        # URLSession, and every type named after it, only in the model's download; other networking nowhere.
        ("SpeechEngine", "let s = URLSession(configuration: .ephemeral)", [], "ModelDownloader.swift"),
        ("SpeechEngine", "final class D: NSObject, URLSessionDataDelegate {}", [], "ModelDownloader.swift"),
        ("SpeechEngine", "let s = URLSession(configuration: .ephemeral)", ["only"]),
        ("SpeechEngine", "let c = URLSessionConfiguration.ephemeral", ["only"], "ModelDownload.swift"),
        ("SorelloApp", "let s = URLSession(configuration: .default)", ["only"], "ModelDownloader.swift"),
        ("SpeechEngine", "let c = NSURLSession.shared", ["only"]),
        ("SpeechEngine", "let c = NWConnection(host: h, port: p, using: .tls)", ["only"], "ModelDownloader.swift"),
        ("SpeechEngine", "import Network", ["only"], "ModelDownloader.swift"),
        ("SpeechEngine", "let c = NSURLConnection(request: r, delegate: d)", ["only"], "ModelDownloader.swift"),
        ("SpeechEngine", "let pattern = /URLSession/", [], "ModelDownloader.swift"),
        # `#/.../#` regex literals are text, escaped delimiters included, and a quote inside one starts no string.
        ("TextRules", "let pattern = #/URLSession/#", []),
        ("TextRules", "let found = text.firstMatch(of: #/[/]print(1)/#)", []),
        ("TextRules", "let pattern = #/abc\\/#URLSession/#", []),
        ("TextRules", "let pattern = ##/a/#print(1)/##", []),
        ("TextRules", "let pattern = #/\n  print(1)  # the call\n  URLSession\n/#\nlet x = 1", []),
        ("TextRules", 'let pattern = #/abc\\/#"def/#; print("x")', ["log"]),
        ("TextRules", 'let r = value.replacing(#/"/#, with: { _ in Swift.print("x"); return "y" })', ["log"]),
        # A bare regex literal's text is ignored when reading what follows it, so its quote starts no string.
        ("TextRules", r"let pattern = /print\(x\)/", []),
        ("TextRules", 'let replacement = text.replacing(/"/, with: "URLSession")', []),
        ("TextRules", 'let replacement = text.replacing(/"/, with: "print(x)")', []),
        ("TextRules", 'if enabled && /.*".*/ ~= text { print(text) }', ["log"]),
        ("TextRules", 'if enabled || /.*".*/ ~= text { print(text) }', ["log"]),
        ("TextRules", 'let m = name ?? /a"/; print(m)', ["log"]),
        ("TextRules", 'let m = flag ? /a"/ : /b"/; print(m)', ["log"]),
        ("TextRules", 'let m = try? /a"b/.wholeMatch(in: s); NSLog("x")', ["log"]),
        ("TextRules", 'let m = try /a"b/.firstMatch(in: s); NSLog("x")', ["log"]),
        ("TextRules", 'let parts = [/a"/, /b"/]; print(parts)', ["log"]),
        ("TextRules", 'let r =\n    /x"/\nprint(r)', ["log"]),
        # Division, and an operator passed as a value, are code.
        ("TextRules", 'let m = text.firstMatch(of: /"/); print("x")', ["log"]),
        ("TextRules", "let ratio = total / count; print(ratio)", ["log"]),
        ("TextRules", "let ratio = (a + b) / 2 / print(c)", ["log"]),
        ("TextRules", "let ratio = values.reduce(1, /); print(ratio / 2)", ["log"]),
        ("TextRules", "let ratio = values.reduce(1, /); print(ratio) // Explain the ratio.", ["log"]),
        ("TextRules", "let ops = [+, -, *, /]; print(x/y)", ["log"]),
        ("TextRules", "let half = a!/2; print(b!/2)", ["log"]),
        ("TextRules", "let n = table[key]!/2; print(n/2)", ["log"]),
        ("TextRules", 'let n = "a/b".count/2; print(n/2)', ["log"]),
        ("TextRules", 'let q = s.split(separator: "/"); print(q)', ["log"]),
        ("TextRules", "let t = a /* c */ / b; print(t / 2)", ["log"]),
        ("TextRules", "foo(combine: /, initial: 1); print(a/b)", ["log"]),
        ("TextRules", "static func / (lhs: V, rhs: V) -> V { print(lhs); return lhs }", ["log"]),
        # A member named like a keyword, and a name that ends in a combining mark, are names: division follows.
        ("TextRules", 'if schedule.repeat/2 > 0 && path.contains("/") { print(path) }', ["log"]),
        ("TextRules", 'let pair = (schedule.repeat/2, "URLSession/")', []),
        ("TextRules", 'let half = schedule.\n    repeat/2 + size("/"); print(half)', ["log"]),
        ("TextRules", 'if order.in/2 > 0 && path.contains("/") { print(path) }', ["log"]),
        ("TextRules", 'let n = plan.try!/2 + size("/"); print(n)', ["log"]),
        ("TextRules", 'if x̂/2 > 0 && path.contains("/") { print(path) }', ["log"]),
        ("TextRules", 'let pair = (x̂/2, "URLSession/")', []),
        ("TextRules", 'let pair = (größe/2, "URLSession/")', []),
        ("TextRules", 'let m = try? /a"b/.firstMatch(in: s); let k = `in`/2; print(k)', ["log"]),
        ("TextRules", "let ok = a / b // print(1)", []),
        ("TextRules", "let f: (Double, Double) -> Double = (/); print(f(a, b)/2)", ["log"]),
        ("TextRules", "let x = a / b / c", []),
        # What looks like a bare regex may have been code, so its text is searched: a banned name in one is
        # reported. `#/.../#` is the way out.
        ("TextRules", "let pattern = /URLSession/", ["only"]),
        # Imports, however they are laid out.
        ("SorelloApp", "import Network", ["only"]),
        ("SorelloApp", "    @preconcurrency import Network", ["only"]),
        ("SorelloApp", "import Foundation; import Network", ["only"]),
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
        ("FileTranscription", "import SpeechEngine\nimport TextRules", []),
        ("FileTranscription", "import AVFoundation", ["FileTranscription"]),
        ("FileTranscription", "import SwiftUI", ["FileTranscription"]),
        ("MacPlatform", "import AppKit", []),
        # Sparkle in its one file, and nowhere else, however the import is written.
        ("SorelloApp", "import Sparkle", [], "Adapters/SparkleUpdater.swift"),
        ("SorelloApp", "@preconcurrency import Sparkle", [], "Adapters/SparkleUpdater.swift"),
        ("SorelloApp", "import Sparkle", ["only"]),
        ("SorelloApp", "import Sparkle", ["only"], "SparkleUpdater.swift"),
        ("SorelloApp", "@preconcurrency import Sparkle", ["only"], "Shell/AppShell.swift"),
        ("SorelloApp", "import class Sparkle.SPUUpdater", ["only"]),
        ("SorelloApp", "import Foundation; import Sparkle", ["only"]),
        ("SorelloUI", "import\n  Sparkle", ["only"]),
        ("SorelloApp", "// import Sparkle is for SparkleUpdater.swift alone", []),
        ("SorelloApp", 'let s = "import Sparkle"', []),
        ("SorelloApp", "import SparkleLike", []),
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
    # The model's host is named nowhere in the sources, in code, strings or comments; the words a user reads are fine.
    for line, expected in [('let u = "https://huggingface.co/x"', True), ("// fetched from HuggingFace", True),
                           ('let h = "cdn.hf.co"', True), ('let h = "https://hf.co/x"', True),
                           ('Text("from Hugging Face")', False), ("self.coordinator = c", False),
                           ('let s = "shf.com"', False), ('let s = "hf.com"', False)]:
        if bool(HOST.search(line)) != expected:
            failures += 1
            print("check-rules self-test: the host rule on %r gave %s" % (line, not expected), file=sys.stderr)
    # A test that imports Sparkle is reported, and a test is read for nothing else.
    for src, expected in [('import Sparkle\nprint("x")', [SPARKLE_RULE]), ('import Testing\nprint("x")', []),
                          ("@testable import SorelloApp\n// import Sparkle", [])]:
        got = [rule for rule, _, _ in lint_test("Tests/SorelloAppTests/File.swift", src)]
        if got != expected:
            failures += 1
            print("check-rules self-test: %r in a test gave %r" % (src, got), file=sys.stderr)
    # A violation is reported on the line it is on.
    numbered = lint_swift("Sources/DesignCore/File.swift", "import Foundation\n\nimport\n  AppKit\n")
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

    # Every rule reads the sources; the tests are read only for Sparkle, which no test may import.
    for top in ("Sources", "Tests"):
        for directory, _, files in sorted(os.walk(os.path.join(ROOT, top))):
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(directory, name)
                relative = os.path.relpath(path, ROOT)
                with open(path, encoding="utf-8") as handle:
                    src = handle.read()
                lint = lint_swift if top == "Sources" else lint_test
                for rule, number, text in lint(relative.replace(os.sep, "/"), src):
                    report(rule, "%s:%d: %s" % (relative, number, text))

    # The old names are gone, comments included, and the model's host is named in no source.
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
                where = "%s:%d: %s" % (os.path.relpath(path, ROOT), number, line.strip())
                if OLD_NAMES.search(line):
                    report("an earlier product's name is still in the code", where)
                if top == "Sources" and HOST.search(line):
                    report("no source names the model's host; it is in Models/model.lock.json", where)

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
