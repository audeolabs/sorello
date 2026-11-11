import DictationCore
import Foundation
import Synchronization

/// One GET, as the download sends it: an address and every header Sorello sets.
struct DownloadRequest: Sendable, Equatable {
    let url: URL
    /// Exactly the headers the contract allows: `User-Agent`, `Accept-Language`, and `Range` when a file is continued.
    let headers: [String: String]
}

/// The head of a response, and its body as it arrives.
struct DownloadResponse: Sendable {
    let status: Int
    /// The response's headers, names in lowercase.
    let headers: [String: String]
    /// The body, in pieces as they arrive. It throws when the connection drops. Dropping it, or cancelling the task
    /// that reads it, stops the request.
    let body: AsyncThrowingStream<Data, any Error>

    /// The `Content-Length` the server declared, when it is a whole number.
    var declaredLength: Int64? { headers["content-length"].flatMap { Int64($0) }.flatMap { $0 >= 0 ? $0 : nil } }
}

/// What carries the download's requests: `ModelDownloader` in the Mac app, a server of the tests' own in the tests.
/// It only sends and receives. Every decision about what to send, which redirect to follow, how long to wait and how
/// much to keep is the download's, in `DownloadRules` and `ModelFetch`, which the tests call.
protocol DownloadTransport: Sendable {
    /// Sends `request` and returns once the head of the response has arrived. A redirect is never followed: it comes
    /// back as it is, for the download to judge. Throws when there is no connection or it drops; cancelling the
    /// calling task stops the request.
    func send(_ request: DownloadRequest) async throws -> DownloadResponse
    /// Lets go of the connection once the download has ended.
    func close()
}

/// The rules of the connection (ARCHITECTURE.md, section 5, "The connection"), as plain functions.
enum DownloadRules {
    /// A connection silent this long is given up as dropped.
    static let silence: TimeInterval = 30
    /// The most redirects one file may take.
    static let redirects = 5
    /// The answers that are redirects.
    static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    /// The request for `url`: a GET with Sorello's name and version, English, and a range when `offset` bytes of the
    /// file are already here. Nothing else is added.
    static func request(_ url: URL, version: String, from offset: Int64) -> DownloadRequest {
        var headers = ["User-Agent": "Sorello/\(version)", "Accept-Language": "en"]
        if offset > 0 { headers["Range"] = "bytes=\(offset)-" }
        return DownloadRequest(url: url, headers: headers)
    }

    /// Where a redirect from `url` leads, resolved against `url`, or nil when it must not be followed: it names no
    /// address, or one that is not HTTPS.
    static func redirect(_ location: String?, from url: URL) -> URL? {
        guard let location, !location.isEmpty, let target = URL(string: location, relativeTo: url)?.absoluteURL,
              target.scheme?.lowercased() == "https", let host = target.host(), !host.isEmpty else { return nil }
        return target
    }

    /// Whether a request may go to `url`: HTTPS always, and plain HTTP only to the very address the pin's source names
    /// when that is plain HTTP to this Mac, which only the verification tool can arrange (`ModelPin.replacingSource`).
    static func permits(_ url: URL, source: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http":
            return source.scheme?.lowercased() == "http" && url.host() == source.host() && url.port == source.port
        default: return false
        }
    }

    /// Where a `206` must start: the `Content-Range` `bytes <first>-<last>/<size>` read for its first byte.
    static func rangeStart(_ contentRange: String?) -> Int64? {
        guard let contentRange, contentRange.hasPrefix("bytes ") else { return nil }
        let range = contentRange.dropFirst("bytes ".count)
        guard let dash = range.firstIndex(of: "-") else { return nil }
        return Int64(range[..<dash])
    }
}

/// Paces progress for the screen: at most one report in every `interval` seconds, plus the last.
struct ProgressPace: Sendable {
    let interval: TimeInterval
    private var last: TimeInterval?

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    /// Whether a report made at `now` should be passed on.
    mutating func admits(at now: TimeInterval) -> Bool {
        if let last, now - last < interval { return false }
        last = now
        return true
    }
}

/// Watches a download for silence. Whatever the download hears resets it; when `limit` seconds pass with nothing
/// heard, it runs `onSilence` once.
final class SilenceWatch: Sendable {
    private struct State {
        var last: TimeInterval
        var silent = false
        var onSilence: (@Sendable () -> Void)?
    }

    private let clock: any SessionClock
    private let limit: TimeInterval
    private let state: Mutex<State>

    init(clock: any SessionClock, limit: TimeInterval) {
        self.clock = clock
        self.limit = limit
        state = Mutex(State(last: clock.now))
    }

    /// Whether the watch gave the download up.
    var wasSilent: Bool { state.withLock { $0.silent } }

    /// Something arrived, or a request was sent: the wait starts again.
    func heard() {
        let now = clock.now
        state.withLock { $0.last = now }
    }

    /// What to do when the download falls silent.
    func whenSilent(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.onSilence = action }
    }

    /// Sleeps until the download has been silent for `limit`, then runs the action; returns early when cancelled.
    func watch() async {
        while !Task.isCancelled {
            let wait = state.withLock { $0.last } + limit - clock.now
            if wait <= 0 {
                let action = state.withLock { state -> (@Sendable () -> Void)? in
                    state.silent = true
                    return state.onSilence
                }
                action?()
                return
            }
            try? await clock.sleep(for: wait)
        }
    }
}
