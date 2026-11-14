import DictionaryKit
import FileTranscription
import Foundation
import Persistence
import SorelloCommand
import SpeechEngine
import Testing
import TextRules

/// The `sorello` command through its one function (ARCHITECTURE.md, section 10, "The command"; section 11), with app
/// bundles of the tests' own and a fake transcriber. Every name, setting and word is invented.
@MainActor
@Suite struct CommandTests {
    let fixture: Fixture
    /// The test app's preferences, in a suite of the test's own.
    let preferences: UserDefaults
    static let identifier = "com.example.sorello-test"

    init() throws {
        fixture = try Fixture()
        preferences = try #require(UserDefaults(suiteName: fixture.suite))
    }

    /// Runs the command once with `transcriber`, as if it had been started at `path`.
    func run(_ arguments: [String], at path: URL, transcriber: FakeTranscriber? = nil,
             sleep: ManualSleep = ManualSleep(), output: Output = Output(),
             preferences: (@Sendable (String) -> UserDefaults?)? = nil) async -> (Int32, Output, Calls) {
        let calls = Calls()
        let fake = transcriber.map { FakeTranscriber(text: $0.text, failure: $0.failure, progress: $0.progress,
                                                     gate: $0.gate, after: $0.after, calls: calls) }
            ?? FakeTranscriber(calls: calls)
        let suite = fixture.suite, identifier = Self.identifier
        let status = await SorelloCommand.run(CommandEnvironment(
            arguments: arguments, executablePath: path.path, applicationSupport: fixture.support,
            preferences: preferences ?? { $0 == identifier ? UserDefaults(suiteName: suite) : nil },
            makeTranscriber: { model in
                calls.made(model)
                return fake
            },
            sleep: sleep.sleep, standardOutput: { output.out($0) }, standardError: { output.error($0) }))
        return (status, output, calls)
    }

    func fake(text: String = "Invented words.", failure: FileTranscriptionFailure? = nil) -> FakeTranscriber {
        FakeTranscriber(text: text, failure: failure, calls: Calls())
    }

    // MARK: - Arguments

    @Test(arguments: [["--help"], ["help"], ["transcribe", "--help"], ["transcribe", "--no-rules", "--help"],
                      ["transcribe", "talk.m4a", "--help"]])
    func helpGoesToStandardOutput(arguments: [String]) async throws {
        // Help needs no app: here the command is not inside one.
        let (status, output, calls) = await run(arguments, at: fixture.root.appendingPathComponent("sorello"))
        #expect(status == 0)
        #expect(output.standardOutput.hasPrefix("usage: sorello transcribe [--no-dictionary] [--no-rules] <file>\n"))
        #expect(output.standardOutput.contains("sorello --version"))
        #expect(output.standardError.isEmpty)
        #expect(calls.models.isEmpty)
    }

    @Test(arguments: [[], ["frobnicate"], ["-h"], ["--frobnicate"], ["transcribe"], ["transcribe", "a.wav", "b.wav"],
                      ["transcribe", "--loud", "a.wav"], ["--version", "now"], ["help", "me"], ["transcribe", "--"],
                      ["--no-rules", "transcribe", "a.wav"]])
    func wrongArgumentsSayHowToUseIt(arguments: [String]) async throws {
        let helper = try fixture.app()
        let (status, output, calls) = await run(arguments, at: helper)
        #expect(status == 64)
        #expect(output.standardOutput.isEmpty)
        #expect(output.standardError.contains("usage: sorello transcribe [--no-dictionary] [--no-rules] <file>\n"))
        if !arguments.isEmpty {
            #expect(output.errorLines.first?.hasPrefix("sorello: ") == true, "Says what is wrong first")
        }
        #expect(calls.models.isEmpty, "Nothing is transcribed")
    }

    /// `--` ends the options, so a file whose name starts with a dash can be given; a lone dash is a file's name.
    @Test func doubleDashEndsTheOptions() async throws {
        let helper = try fixture.app()
        for (arguments, name) in [(["transcribe", "--", "--no-rules"], "--no-rules"), (["transcribe", "-"], "-"),
                                  (["transcribe", "--no-dictionary", "--", "-x.wav"], "-x.wav")] {
            let (status, _, calls) = await run(arguments, at: helper)
            #expect(status == 0)
            #expect(calls.calls.first?.file.lastPathComponent == name)
            #expect(calls.calls.first?.rules != nil, "The rules stay on")
        }
    }

    /// A relative file is found from the directory the command was run in.
    @Test func aRelativeFileIsFoundFromTheCurrentDirectory() async throws {
        let helper = try fixture.app()
        let (_, _, calls) = await run(["transcribe", "talk.m4a"], at: helper)
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("talk.m4a")
        #expect(calls.calls.first?.file.standardizedFileURL == expected.standardizedFileURL)
    }

    // MARK: - Its app

    @Test func versionNamesTheAppThroughAChainOfLinks() async throws {
        let link = try fixture.link(to: try fixture.app(name: "Sorello Test", version: "0.0.1", build: "269"))
        let (status, output, _) = await run(["--version"], at: link)
        #expect(status == 0)
        #expect(output.standardOutput == "Sorello Test 0.0.1 (269)\n")
        #expect(output.standardError.isEmpty)
    }

    /// A command outside an app finds none: a copy, a hard link, the build tree's executable, a command in the wrong
    /// place in an app, an app that names no bundle identifier, and a path that is not there.
    @Test func withoutAnAppAroundItTheCommandSaysSo() async throws {
        let helper = try fixture.app()
        let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let copy = bin.appendingPathComponent("sorello")
        try FileManager.default.copyItem(at: helper, to: copy)
        let hard = bin.appendingPathComponent("sorello-hard")
        try FileManager.default.linkItem(at: helper, to: hard)
        let tree = fixture.root.appendingPathComponent(".build/debug", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data().write(to: tree.appendingPathComponent("sorello-command"))
        let misplaced = helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: misplaced, withIntermediateDirectories: true)
        try Data().write(to: misplaced.appendingPathComponent("sorello"))
        let anonymous = try fixture.app(name: "Anonymous", identifier: nil)
        let paths = [copy, hard, tree.appendingPathComponent("sorello-command"), misplaced.appendingPathComponent("sorello"),
                     anonymous, fixture.root.appendingPathComponent("absent/sorello")]
        let file = try fixture.tone()
        for path in paths {
            for arguments in [["--version"], ["transcribe", file.path]] {
                let (status, output, calls) = await run(arguments, at: path)
                #expect(status == 69, "\(path.lastPathComponent)")
                #expect(output.standardOutput.isEmpty)
                #expect(output.errorLines.count == 1 && output.standardError.hasPrefix("sorello: can't find the Sorello app"))
                #expect(calls.models.isEmpty)
            }
        }
    }

    @Test func anAppWhosePinCannotBeReadIsDamaged() async throws {
        let helper = try fixture.app(pin: Data("not a pin".utf8))
        let (status, output, calls) = await run(["transcribe", "talk.m4a"], at: helper)
        #expect(status == 69)
        #expect(output.standardOutput.isEmpty && output.errorLines.count == 1)
        #expect(output.standardError.hasPrefix("sorello: Sorello Test is damaged"))
        #expect(calls.models.isEmpty)
        #expect(await run(["--version"], at: helper).0 == 0, "Its version can still be told")
    }

    // MARK: - Its model, dictionary and rules

    /// The command transcribes with its app's model, in that app's store, its dictionary's words that apply
    /// everywhere, and its text rules, and writes the text and one newline.
    @Test func itUsesItsAppsModelDictionaryAndRules() async throws {
        let link = try fixture.link(to: try fixture.app())
        preferences.set(false, forKey: "spokenNumbers")
        preferences.set(true, forKey: "pressEnterCommand")
        preferences.set("[spoken]", forKey: "promptTag")
        let macros = MacroStore(fileURL: fixture.data().appendingPathComponent("macros.json"))
        let macro = try macros.add(command: "blue bird", text: "Synthetic replacement.")
        try fixture.write(Data("""
            {"apps":[{"id":"com.example.chat","name":"Chat"}],"entries":[{"strength":2,"text":"Zorblax"},\
            {"apps":["com.example.chat"],"strength":1,"text":"Quint"}],"ignore":[],"version":1}
            """.utf8), "dictionary.json")

        let (status, output, calls) = await run(["transcribe", "talk.m4a"], at: link)
        #expect(status == 0)
        #expect(output.standardOutput == "Invented words.\n")
        #expect(output.standardError.isEmpty)
        let model = try #require(calls.models.first)
        #expect(model.model.storeDirectory.standardizedFileURL
                == fixture.data().appendingPathComponent("Models", isDirectory: true).standardizedFileURL)
        #expect(model.model.carriedDirectory == nil && model.model.build?.manifestSHA256 == Fixture.manifestDigest)
        #expect(model.dictionary.entries == [DictionaryEntry(text: "Zorblax", strength: 2)],
                "Only the words that apply everywhere")
        #expect(calls.calls.first?.rules == TextRuleOptions(macros: [macro], pressEnterCommand: true, spokenNumbers: false,
                                                            spokenDelimiters: false, promptTag: "[spoken]"))
    }

    @Test func aModelTheAppCarriesIsUsed() async throws {
        let helper = try fixture.app(carries: Fixture.manifest)
        let (_, _, calls) = await run(["transcribe", "talk.m4a"], at: helper)
        let carried = helper.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Model", isDirectory: true)
        #expect(calls.models.first?.model.carriedDirectory?.standardizedFileURL == carried.standardizedFileURL)
    }

    @Test func noWordsHeardWritesNothing() async throws {
        let helper = try fixture.app()
        let (status, output, _) = await run(["transcribe", "talk.m4a"], at: helper, transcriber: fake(text: ""))
        #expect(status == 0)
        #expect(output.standardOutput.isEmpty && output.standardError.isEmpty)
    }

    /// `--no-rules` gives the transcript as heard and `--no-dictionary` leaves the dictionary out; neither reads what
    /// it leaves out, so a damaged file there goes unmentioned.
    @Test func theFlagsLeaveOutTheRulesAndTheDictionary() async throws {
        let helper = try fixture.app()
        try fixture.write(Data("damaged".utf8), "macros.json")
        try fixture.write(Data("damaged".utf8), "dictionary.json")
        let none: @Sendable (String) -> UserDefaults? = { _ in nil }

        let (status, output, calls) = await run(["transcribe", "--no-rules", "--no-dictionary", "talk.m4a"], at: helper,
                                                preferences: none)
        #expect(status == 0 && output.standardError.isEmpty)
        #expect(calls.calls.first?.rules == nil)
        #expect(calls.models.first?.dictionary == .empty)

        let (_, rulesOnly, rulesCalls) = await run(["transcribe", "talk.m4a", "--no-dictionary"], at: helper)
        #expect(rulesCalls.calls.first?.rules != nil && rulesCalls.models.first?.dictionary == .empty)
        #expect(rulesOnly.errorLines.count == 1 && rulesOnly.standardError.contains("macros.json"))

        let (_, dictionaryOnly, dictionaryCalls) = await run(["transcribe", "--no-rules", "talk.m4a"], at: helper)
        #expect(dictionaryCalls.calls.first?.rules == nil)
        #expect(dictionaryOnly.errorLines.count == 1 && dictionaryOnly.standardError.contains("dictionary.json"))
    }

    /// A rules file that cannot be read counts as empty: the command says so, goes on, and leaves it exactly as it
    /// was.
    @Test func unreadableRulesFilesAreReportedAndLeftAlone() async throws {
        let helper = try fixture.app()
        try fixture.write(Data(#"{"version":1,"macros":"#.utf8), "macros.json")
        try fixture.write(Data(#"{"version":7}"#.utf8), "dictionary.json")
        let before = Fixture.snapshot(fixture.data())
        let none: @Sendable (String) -> UserDefaults? = { _ in nil }
        let (status, output, calls) = await run(["transcribe", "talk.m4a"], at: helper, preferences: none)
        #expect(status == 0)
        #expect(output.standardOutput == "Invented words.\n")
        #expect(output.errorLines.count == 3 && output.errorLines.allSatisfy { $0.hasPrefix("sorello: can't read") })
        #expect(calls.calls.first?.rules == TextRuleOptions(macros: [], pressEnterCommand: false, spokenNumbers: true,
                                                            spokenDelimiters: false, promptTag: "[dictated]"),
                "The default rules, without macros")
        #expect(calls.models.first?.dictionary == .empty)
        #expect(Fixture.snapshot(fixture.data()) == before, "Byte for byte as they were")
    }

    /// The command writes nothing into the app's data: not when it is missing, and not when it is full.
    @Test func itWritesNothingInTheAppsData() async throws {
        let helper = try fixture.app()
        for transcriber in [fake(), fake(failure: .modelMissing)] {
            _ = await run(["transcribe", "talk.m4a"], at: helper, transcriber: transcriber)
            #expect(!FileManager.default.fileExists(atPath: fixture.data().path), "No directory is made")
        }
        preferences.set(true, forKey: "spokenDelimiters")
        let macros = MacroStore(fileURL: fixture.data().appendingPathComponent("macros.json"))
        try macros.add(command: "blue bird", text: "Synthetic replacement.")
        try fixture.write(Data(#"{"apps":[],"entries":[],"ignore":[],"version":1}"#.utf8), "dictionary.json")
        let before = Fixture.snapshot(fixture.support)
        let settings = preferences.dictionaryRepresentation().filter { ["spokenDelimiters", "spokenNumbers"].contains($0.key) }
        for transcriber in [fake(), fake(failure: .failed)] {
            _ = await run(["transcribe", "talk.m4a"], at: helper, transcriber: transcriber)
        }
        #expect(Fixture.snapshot(fixture.support) == before)
        #expect(preferences.dictionaryRepresentation().filter { ["spokenDelimiters", "spokenNumbers"].contains($0.key) }
                    .mapValues { "\($0)" } == settings.mapValues { "\($0)" })
    }

    // MARK: - Failures

    @Test(arguments: [
        (FileTranscriptionFailure.cannotOpen, Int32(66), "sorello: can't open talk.m4a"),
        (.unreadable, 65, "sorello: can't read talk.m4a. Sorello reads WAV"),
        (.modelMissing, 69, "sorello: the speech model is not downloaded. Open Sorello Test and download it there."),
        (.noModelForThisMac, 69, "sorello: Sorello Test has no speech model for this Mac yet."),
        (.modelUnavailable, 70, "sorello: the speech model could not be loaded."),
        (.failed, 70, "sorello: couldn't transcribe talk.m4a"),
    ])
    func eachFailureHasItsStatusAndOneLine(failure: FileTranscriptionFailure, status: Int32, message: String) async throws {
        let helper = try fixture.app()
        let (got, output, _) = await run(["transcribe", "talk.m4a"], at: helper, transcriber: fake(failure: failure))
        #expect(got == status)
        #expect(output.standardOutput.isEmpty, "A failure writes no text")
        #expect(output.errorLines.count == 1 && output.standardError.hasPrefix(message))
    }

    /// A message is one line however the file or argument it quotes is named: line breaks and other control
    /// characters are written as escapes, so none reaches the terminal.
    @Test func quotedNamesStayOnOneLine() async throws {
        let helper = try fixture.app()
        let (status, output, _) = await run(["transcribe", "missing\nsecond\u{1B}[31m.wav"], at: helper,
                                            transcriber: fake(failure: .cannotOpen))
        #expect(status == 66)
        #expect(output.errorLines == ["sorello: can't open missing\\nsecond\\u{1b}[31m.wav"])
        for arguments in [["--fr\u{1B}[2Job"], ["transcribe", "--x\ny", "a.wav"], ["help\u{2028}x"]] {
            let (wrong, said, _) = await run(arguments, at: helper)
            #expect(wrong == 64)
            let first = try #require(said.errorLines.first)
            #expect(first.hasPrefix("sorello: unknown "))
            #expect(!said.standardError.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{2028}" })
            #expect(said.errorLines.dropFirst().first?.hasPrefix("usage: ") == true, "The reason took one line")
        }
    }

    /// The shipped transcriber over an app whose model is not on this Mac, as a fresh install is: the file is
    /// checked first, then the model is found missing, or found to have no build for this Mac.
    @Test func theRealTranscriberWithoutAModel() async throws {
        let fits = try fixture.app(name: "Fits")
        let unfit = try fixture.app(name: "Unfit", identifier: "com.example.sorello-unfit", pin: Fixture.pin(macOS: "99.0"))
        let tone = try fixture.tone()
        let text = fixture.root.appendingPathComponent("notes.txt")
        try Data("Invented words, not audio.\n".utf8).write(to: text)
        func real(_ arguments: [String], at helper: URL) async -> (Int32, Output) {
            let output = Output()
            let status = await SorelloCommand.run(CommandEnvironment(
                arguments: arguments, executablePath: helper.path, applicationSupport: fixture.support,
                preferences: { _ in nil }, makeTranscriber: SorelloCommand.engineTranscriber,
                sleep: { _ in }, standardOutput: { output.out($0) }, standardError: { output.error($0) }))
            return (status, output)
        }
        let missing = await real(["transcribe", "--no-rules", tone.path], at: fits)
        #expect(missing.0 == 69 && missing.1.standardError.contains("not downloaded"))
        let none = await real(["transcribe", "--no-rules", tone.path], at: unfit)
        #expect(none.0 == 69 && none.1.standardError.contains("no speech model for this Mac"))
        #expect(await real(["transcribe", "--no-rules", text.path], at: fits).0 == 65)
        #expect(await real(["transcribe", "--no-rules", fixture.root.appendingPathComponent("absent.wav").path], at: fits).0
                == 66)
        #expect(await real(["transcribe", "--no-rules", fixture.root.path], at: fits).0 == 66)
        for result in [missing, none] { #expect(result.1.standardOutput.isEmpty) }
    }

    // MARK: - The note about preparing

    /// If the model is still preparing two seconds after the command began waiting for it, the command says so once.
    @Test func aSlowPreparationIsMentionedOnce() async throws {
        let helper = try fixture.app()
        let sleep = ManualSleep(), transcribing = Gate()
        let transcriber = FakeTranscriber(progress: [.preparingModel, .preparingModel], gate: transcribing,
                                          after: [.transcribing(read: 0, length: 9), .preparingModel],
                                          calls: Calls())
        let output = Output()
        let run = Task {
            await self.run(["transcribe", "talk.m4a"], at: helper, transcriber: transcriber, sleep: sleep, output: output)
        }
        await eventually { !sleep.requests.isEmpty }
        #expect(sleep.requests == [.seconds(2)], "One delay, of two seconds")
        sleep.gate.open()
        await eventually { !output.standardError.isEmpty }
        transcribing.open()
        let (status, _, _) = await run.value
        #expect(status == 0)
        #expect(output.errorLines == ["sorello: preparing the speech model; the first time on this Mac this can take a few minutes"])
        #expect(output.standardOutput == "Invented words.\n")
    }

    /// A preparation that ends within two seconds is never mentioned.
    @Test func aQuickPreparationIsNotMentioned() async throws {
        let helper = try fixture.app()
        let sleep = ManualSleep()
        let transcriber = FakeTranscriber(progress: [.preparingModel, .transcribing(read: 0, length: 9)], calls: Calls())
        let (status, output, _) = await run(["transcribe", "talk.m4a"], at: helper, transcriber: transcriber,
                                            sleep: sleep)
        sleep.gate.open()
        try await Task.sleep(for: .milliseconds(50))
        #expect(status == 0 && output.standardError.isEmpty)
    }
}
