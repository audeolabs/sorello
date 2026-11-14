import Darwin
import Foundation
import SorelloCommand

// sorello-command, shipped in every app as Contents/Helpers/sorello (ARCHITECTURE.md, section 10, "The command"). This
// file only hands the command the real world: its arguments, the path it was started by, the user's Application
// Support directory and preferences, the speech engine, a clock, and the two output streams. It installs no signal
// handler, so an interrupted command dies of the signal as any command does.

/// The path this process was started by, as the system recorded it: a symbolic link on the PATH stays a link here,
/// for the command to follow. A relative path is resolved against the directory it was started in.
func startedPath() -> String {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size))
    if _NSGetExecutablePath(&buffer, &size) != 0 {
        // Too long for the first buffer; `size` now says how long it is.
        buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return "" }
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
let status = await SorelloCommand.run(CommandEnvironment(
    arguments: Array(CommandLine.arguments.dropFirst()),
    executablePath: startedPath(),
    applicationSupport: applicationSupport,
    preferences: { UserDefaults(suiteName: $0) },
    makeTranscriber: SorelloCommand.engineTranscriber,
    sleep: { try? await Task.sleep(for: $0) },
    standardOutput: { FileHandle.standardOutput.write(Data($0.utf8)) },
    standardError: { FileHandle.standardError.write(Data($0.utf8)) }))
exit(status)
