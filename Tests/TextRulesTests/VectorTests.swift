import Foundation
import TestSupport
import Testing
import TextRules

/// Runs every case of the shared vectors in `Tests/Vectors`, which the Linux port runs too. Nothing is skipped, and
/// a case with a field this suite does not understand fails rather than being ignored.
@Suite struct VectorTests {
    @Test func numberVectors() throws {
        let file = try Vectors.decode(NumberVectors.self, from: "number-vectors.json")
        #expect(file.version == 1)
        #expect(file.format.count >= 100)
        for item in file.format {
            #expect(SpokenNumberFormatter.format(item.input) == item.expected, "[\(item.rule ?? "")] \(item.input)")
        }
    }

    @Test(arguments: ["process", "prompt_tag"])
    func processVectors(section: String) throws {
        let file = try Vectors.decode(DictationVectors.self, from: "dictation-vectors.json")
        #expect(file.version == 1)
        let cases = try #require(section == "process" ? file.process : file.promptTag)
        #expect(cases.count >= (section == "process" ? 50 : 10))
        for (index, item) in cases.enumerated() {
            let options = TextRuleOptions(
                macros: (item.macros ?? []).map { VoiceMacro(command: $0.command, text: $0.payload) },
                pressEnterCommand: item.pressEnterEnabled ?? true, spokenNumbers: item.spokenNumbersEnabled ?? true,
                spokenDelimiters: item.spokenDelimitersEnabled ?? true, promptTag: item.promptTag ?? "")
            // A case names a prompt tag only when it is a prompt-style dictation; context is unknown in every case.
            let result = DictationRules.process(item.input, options: options, promptStyle: item.promptTag != nil)
            let label = "\(section)[\(index)] \(item.input.debugDescription)"
            let expected = item.expected
            #expect(expected.checksSomething, "\(label) checks nothing")
            #expect(result.heard == item.input, "\(label): heard")
            if let raw = expected.raw { #expect(result.spoken == raw, "\(label): raw") }
            if let output = expected.output { #expect(result.text == output, "\(label): output") }
            if let pressEnter = expected.pressEnter { #expect(result.pressEnter == pressEnter, "\(label): press_enter") }
            if let usedMacro = expected.usedMacro { #expect(result.usedMacro == usedMacro, "\(label): used_macro") }
            if let tagged = expected.addedPromptTag {
                #expect(result.addedPromptTag == tagged, "\(label): added_prompt_tag")
            }
            if let status = expected.status { #expect(Self.status(of: result) == status, "\(label): status") }
        }
    }

    @Test func spokenDelimiterVectors() throws {
        let file = try Vectors.decode(DictationVectors.self, from: "dictation-vectors.json")
        let cases = try #require(file.spokenDelimiters)
        #expect(cases.count >= 100)
        #expect(cases.filter { $0.origin == "swift" }.count >= 86, "every case of the original suite is here")
        for (index, item) in cases.enumerated() {
            // Spoken numbers are pinned by number-vectors.json; these cases test delimiters alone.
            for (enabled, want) in [(true, item.expected), (false, item.expectedDisabled ?? item.input)] {
                let options = TextRuleOptions(pressEnterCommand: true, spokenNumbers: false, spokenDelimiters: enabled,
                                              promptTag: "")
                let got = DictationRules.process(item.input, options: options, promptStyle: false).text
                #expect(got == want, "spoken_delimiters[\(index)]\(enabled ? "" : " disabled") \(item.input.debugDescription)")
            }
        }
    }

    /// The vectors' `status` is the label the earlier app showed in its history. It is a function of the flags, so
    /// checking it checks them.
    private static func status(of result: TextRuleResult) -> String {
        var status = result.usedMacro ? "Local voice macro" : "Local transcription"
        if result.addedPromptTag { status += "; added prompt tag" }
        return result.pressEnter ? "\(status); detected press enter command" : status
    }
}

// MARK: - Vector files

private struct NumberVectors: Decodable {
    struct Case: Decodable {
        var rule: String?
        var input: String
        var expected: String
    }

    var version: Int
    var format: [Case]
}

private struct DictationVectors: Decodable {
    struct Macro: Decodable {
        var command: String
        var payload: String
    }

    struct Expected: Decodable {
        var raw: String?
        var output: String?
        var pressEnter: Bool?
        var usedMacro: Bool?
        var addedPromptTag: Bool?
        var status: String?

        var checksSomething: Bool {
            raw != nil || output != nil || pressEnter != nil || usedMacro != nil || addedPromptTag != nil
                || status != nil
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case raw, output, status
            case pressEnter = "press_enter", usedMacro = "used_macro", addedPromptTag = "added_prompt_tag"
        }

        init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, known: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            raw = try container.decodeIfPresent(String.self, forKey: .raw)
            output = try container.decodeIfPresent(String.self, forKey: .output)
            pressEnter = try container.decodeIfPresent(Bool.self, forKey: .pressEnter)
            usedMacro = try container.decodeIfPresent(Bool.self, forKey: .usedMacro)
            addedPromptTag = try container.decodeIfPresent(Bool.self, forKey: .addedPromptTag)
            status = try container.decodeIfPresent(String.self, forKey: .status)
        }
    }

    struct ProcessCase: Decodable {
        var input: String
        var macros: [Macro]?
        var pressEnterEnabled: Bool?
        var spokenNumbersEnabled: Bool?
        var spokenDelimitersEnabled: Bool?
        var promptTag: String?
        var expected: Expected

        enum CodingKeys: String, CodingKey, CaseIterable {
            case input, macros, expected, origin, comment
            case pressEnterEnabled = "press_enter_enabled", spokenNumbersEnabled = "spoken_numbers_enabled"
            case spokenDelimitersEnabled = "spoken_delimiters_enabled", promptTag = "prompt_tag"
        }

        init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, known: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            input = try container.decode(String.self, forKey: .input)
            macros = try container.decodeIfPresent([Macro].self, forKey: .macros)
            pressEnterEnabled = try container.decodeIfPresent(Bool.self, forKey: .pressEnterEnabled)
            spokenNumbersEnabled = try container.decodeIfPresent(Bool.self, forKey: .spokenNumbersEnabled)
            spokenDelimitersEnabled = try container.decodeIfPresent(Bool.self, forKey: .spokenDelimitersEnabled)
            promptTag = try container.decodeIfPresent(String.self, forKey: .promptTag)
            expected = try container.decode(Expected.self, forKey: .expected)
        }
    }

    struct DelimiterCase: Decodable {
        var input: String
        var expected: String
        var expectedDisabled: String?
        var origin: String?

        enum CodingKeys: String, CodingKey {
            case input, expected, origin
            case expectedDisabled = "expected_disabled"
        }
    }

    var version: Int
    var process: [ProcessCase]?
    var spokenDelimiters: [DelimiterCase]?
    var promptTag: [ProcessCase]?

    enum CodingKeys: String, CodingKey {
        case version, process
        case spokenDelimiters = "spoken_delimiters", promptTag = "prompt_tag"
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private struct UnknownVectorField: Error, CustomStringConvertible {
    var keys: [String]
    var description: String { "unknown vector fields: \(keys.joined(separator: ", "))" }
}

private func rejectUnknownKeys(in decoder: any Decoder, known: [String]) throws {
    let unknown = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        .filter { !known.contains($0) }
    if !unknown.isEmpty { throw UnknownVectorField(keys: unknown.sorted()) }
}
