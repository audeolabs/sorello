import AppKit
import Foundation

/// The app's entry point. `Sources/Sorello/main.swift` calls `run()` and nothing else.
public enum SorelloMain {
    /// Starts the menu-bar app, or one of the two verification modes the command line asks for, and never returns.
    @MainActor
    public static func run() -> Never {
        switch LaunchMode(arguments: Array(CommandLine.arguments.dropFirst())) {
        case .app(let showsSetup):
            AppShell.run(showsSetup: showsSetup)
        case .selfTest(let files, let model, let forcesCPU, let downloads):
            SelfTest.run(files: files, model: model, forcesCPU: forcesCPU, downloads: downloads)
        case .snapshots(let directory):
            WindowSnapshots.run(into: directory)
        case .usage(let message):
            Console.error(message)
            exit(64)
        }
    }
}

/// What the command line asks for (ARCHITECTURE.md, section 11).
///
///     Sorello                                      the menu-bar app
///     Sorello --no-setup                           the app, without opening setup (for verification)
///     Sorello --self-test [--model <dir> | --download] [--cpu] <wav>…
///                                                  dictate each file through the real session; exit 0 or 1. `--cpu`
///                                                  runs the encoder on the CPU, as on a Mac without a Neural Engine.
///                                                  `--download` first downloads the model into a temporary store
///     Sorello --snapshots <dir>                    render the menu-bar item, windows and setup; list the menu
///
/// The app ignores arguments it does not know, because the system can pass its own when it launches an app.
nonisolated enum LaunchMode: Equatable {
    case app(showsSetup: Bool)
    case selfTest(files: [URL], model: URL?, forcesCPU: Bool, downloads: Bool = false)
    case snapshots(URL)
    case usage(String)

    static let usage = """
        usage: Sorello [--no-setup]
               Sorello --self-test [--model <bundle-dir> | --download] [--cpu] <file.wav>...
               Sorello --snapshots <output-directory>
        """

    init(arguments: [String]) {
        guard let first = arguments.first else {
            self = .app(showsSetup: true)
            return
        }
        switch first {
        case "--self-test":
            var rest = arguments.dropFirst()
            var model: URL?
            var forcesCPU = false
            var downloads = false
            var files: [URL] = []
            while let argument = rest.popFirst() {
                if argument == "--cpu" {
                    forcesCPU = true
                } else if argument == "--download" {
                    downloads = true
                } else if argument == "--model" {
                    guard let path = rest.popFirst() else {
                        self = .usage(Self.usage)
                        return
                    }
                    model = URL(fileURLWithPath: path, isDirectory: true)
                } else if argument.hasPrefix("-") {
                    self = .usage(Self.usage)
                    return
                } else {
                    files.append(URL(fileURLWithPath: argument))
                }
            }
            // A model given on the command line and a download are two ways to the model; a test proves one.
            self = files.isEmpty || (downloads && model != nil) ? .usage(Self.usage)
                : .selfTest(files: files, model: model, forcesCPU: forcesCPU, downloads: downloads)
        case "--snapshots":
            guard arguments.count == 2 else {
                self = .usage(Self.usage)
                return
            }
            self = .snapshots(URL(fileURLWithPath: arguments[1], isDirectory: true))
        case "-h", "--help":
            self = .usage(Self.usage)
        default:
            self = .app(showsSetup: !arguments.contains("--no-setup"))
        }
    }
}

/// The two command-line modes' output. Only the self-test and the snapshots write here, for the person who ran them:
/// the text a synthetic recording would have inserted, timings and file names. The app itself never does.
nonisolated enum Console {
    static func line(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
