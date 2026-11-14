import Foundation

/// What the command was asked to do (ARCHITECTURE.md, section 10, "The command", "Arguments").
enum CommandRequest: Equatable {
    /// How to use it, on standard output.
    case help
    case version
    /// Transcribe `file`, as typed, with or without the dictionary and the text rules.
    case transcribe(file: String, dictionary: Bool, rules: Bool)
    /// The arguments are wrong: `reason` says how, when one line can, and how to use it follows on standard error.
    case wrong(reason: String?)

    /// `sorello transcribe [--no-dictionary] [--no-rules] <file>`, `sorello --version`, and `sorello --help`,
    /// `sorello help` or `sorello transcribe --help`. Options may come before or after the file; `--` ends them, so a
    /// file whose name starts with a dash can be given after it. A lone `-` is a file's name.
    init(_ arguments: [String]) {
        guard let command = arguments.first else {
            self = .wrong(reason: nil)
            return
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "--help", "help":
            self = rest.isEmpty ? .help : .wrong(reason: String(localized: "\(command) takes no arguments"))
        case "--version":
            self = rest.isEmpty ? .version : .wrong(reason: String(localized: "--version takes no arguments"))
        case "transcribe":
            self = Self.transcribe(rest)
        default:
            self = .wrong(reason: command.hasPrefix("-") ? String(localized: "unknown option: \(command)")
                                                         : String(localized: "unknown command: \(command)"))
        }
    }

    private static func transcribe(_ arguments: [String]) -> CommandRequest {
        var files: [String] = [], dictionary = true, rules = true, options = true
        for argument in arguments {
            if options && argument == "--" {
                options = false
            } else if options && argument.hasPrefix("-") && argument != "-" {
                switch argument {
                case "--help": return .help
                case "--no-dictionary": dictionary = false
                case "--no-rules": rules = false
                default: return .wrong(reason: String(localized: "unknown option: \(argument)"))
                }
            } else {
                files.append(argument)
            }
        }
        guard files.count == 1, let file = files.first else {
            return .wrong(reason: files.isEmpty ? String(localized: "transcribe needs a file")
                                                : String(localized: "transcribe takes one file"))
        }
        return .transcribe(file: file, dictionary: dictionary, rules: rules)
    }

    /// How to use the command, for `--help` and after wrong arguments.
    static var usage: String {
        String(localized: """
            usage: sorello transcribe [--no-dictionary] [--no-rules] <file>
                   sorello --version
                   sorello --help

            Writes the text of an audio or video file to standard output, using the speech model, dictionary and \
            text rules of the Sorello app this command is in. Sorello reads WAV, AIFF, CAF, FLAC, MP3, M4A and Ogg \
            files, and the sound of MP4 and MOV videos.

              --no-dictionary  transcribe without the dictionary
              --no-rules       give the words as heard, without the text rules

            """)
    }
}
