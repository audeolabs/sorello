import os

/// The only way Sorello writes to a log (ARCHITECTURE.md, section 9). An event is a name fixed at compile time
/// and a few numbers, so a transcript, a path or any other content cannot get into it by construction. Events are
/// logged at the debug level, which the system does not keep unless someone is streaming the log.
public enum Diagnostics {
    private static let logger = Logger(subsystem: "sorello", category: "diagnostics")

    /// Records that `event` happened. `values` are counts, durations in seconds, or enumeration raw values.
    public static func record(_ event: StaticString, _ values: KeyValuePairs<StaticString, Double> = [:]) {
        var line = String(describing: event)
        for (name, value) in values {
            line += " \(name)=\(value)"
        }
        logger.debug("\(line, privacy: .public)")
    }
}
