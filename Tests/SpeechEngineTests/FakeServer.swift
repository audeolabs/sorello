import Foundation
import Synchronization
@testable import SpeechEngine

/// A server of the tests' own, in place of the network: it serves invented files by address, and for any address it
/// can be told to answer otherwise, once per request, in order. Nothing here opens a connection.
final class FakeServer: DownloadTransport {
    /// How one request is answered.
    enum Answer: Sendable {
        /// The file, honouring a range.
        case serve
        /// The whole file with 200, whatever range was asked.
        case ignoreRange
        /// This status and an empty body.
        case status(Int)
        /// A redirect to `location`, with this status.
        case redirect(String, status: Int = 302)
        /// The first `bytes` of what would be served, then the connection drops.
        case cutOff(after: Int)
        /// The first `bytes`, then nothing more until the reader gives up.
        case stall(after: Int)
        /// No answer at all until the reader gives up.
        case silentHead
        /// No connection.
        case noConnection
        /// These bytes in place of the file, with 200, and a `Content-Length` when `declared`.
        case body(Data, declared: Bool)
        /// The file with a `Content-Length` larger than what is sent, and the body ends cleanly early.
        case shortBody
    }

    private struct State {
        var files: [String: Data]
        var answers: [String: [Answer]] = [:]
        var requests: [DownloadRequest] = []
        var stalled: [AsyncThrowingStream<Data, any Error>.Continuation] = []
        var closed = 0
    }

    private let state: Mutex<State>
    /// Bytes in each piece of a body.
    let piece = 4096

    init(files: [String: Data]) {
        state = Mutex(State(files: files))
    }

    /// Makes the next requests for `address` get `answers`, one each, before it is served as usual again.
    func answer(_ address: String, _ answers: Answer...) {
        state.withLock { $0.answers[address, default: []] += answers }
    }

    /// Puts a file at `address`.
    func put(_ address: String, _ data: Data) {
        state.withLock { $0.files[address] = data }
    }

    /// Every request, in the order it came.
    var requests: [DownloadRequest] { state.withLock { $0.requests } }

    /// The addresses asked for, in order.
    var addresses: [String] { requests.map(\.url.absoluteString) }

    /// How many times a run let go of the connection.
    var closed: Int { state.withLock { $0.closed } }

    func close() {
        state.withLock { $0.closed += 1 }
    }

    func send(_ request: DownloadRequest) async throws -> DownloadResponse {
        let address = request.url.absoluteString
        let (answer, file) = state.withLock { state -> (Answer, Data?) in
            state.requests.append(request)
            var answer = Answer.serve
            if var queue = state.answers[address], !queue.isEmpty {
                answer = queue.removeFirst()
                state.answers[address] = queue
            }
            return (answer, state.files[address])
        }
        switch answer {
        case .noConnection:
            throw URLError(.notConnectedToInternet)
        case .silentHead:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        case .status(let status):
            return respond(status, [:], Data())
        case .redirect(let location, let status):
            return respond(status, ["location": location], Data())
        case .body(let data, let declared):
            return respond(200, declared ? ["content-length": "\(data.count)"] : [:], data)
        default:
            break
        }
        guard let file else { return respond(404, [:], Data()) }
        var status = 200, headers: [String: String] = [:], data = file
        if case .serve = answer, let range = request.headers["Range"], range.hasPrefix("bytes="),
           let start = Int(range.dropFirst("bytes=".count).dropLast()), range.hasSuffix("-") {
            guard start < file.count else { return respond(416, [:], Data()) }
            status = 206
            headers["content-range"] = "bytes \(start)-\(file.count - 1)/\(file.count)"
            data = file.subdata(in: start..<file.count)
        }
        headers["content-length"] = "\(data.count)"
        switch answer {
        case .cutOff(let bytes):
            return respond(status, headers, data.prefix(bytes), ending: URLError(.networkConnectionLost))
        case .stall(let bytes):
            return respond(status, headers, data.prefix(bytes), stalls: true)
        case .shortBody:
            return respond(status, headers, data.prefix(data.count / 2))
        default:
            return respond(status, headers, data)
        }
    }

    /// A response whose body is `data` in pieces, then its end: clean, with `ending`, or never when it `stalls`.
    private func respond(_ status: Int, _ headers: [String: String], _ data: Data, ending: (any Error)? = nil,
                         stalls: Bool = false) -> DownloadResponse {
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + piece, data.endIndex)
            continuation.yield(data.subdata(in: offset..<end))
            offset = end
        }
        if stalls {
            state.withLock { $0.stalled.append(continuation) }
        } else if let ending {
            continuation.finish(throwing: ending)
        } else {
            continuation.finish()
        }
        return DownloadResponse(status: status, headers: headers, body: body)
    }
}
