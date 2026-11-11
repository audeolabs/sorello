import Foundation
import Synchronization

/// The one place Sorello opens a network connection (ARCHITECTURE.md, section 9, invariant 1): the model's download,
/// over one session that keeps no cookies, no cache and no credentials. It only carries requests and hands back what
/// arrives. It never follows a redirect; what to send, which redirect to follow, how long to wait and how much to keep
/// are decided in `DownloadRules` and `ModelFetch`.
final class ModelDownloader: DownloadTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = DownloadRules.silence
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: configuration)
    }

    func send(_ request: DownloadRequest) async throws -> DownloadResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: urlRequest)
        let receiver = DownloadReceiver()
        task.delegate = receiver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.awaitHead(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func close() {
        session.invalidateAndCancel()
    }
}

/// One request's events: the head once, then the body's pieces, then its end. The end may come before anyone waits
/// for the head (a request cancelled at once ends at once), so it is kept and handed to a late waiter.
final class DownloadReceiver: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var head: CheckedContinuation<DownloadResponse, any Error>?
        var body: AsyncThrowingStream<Data, any Error>.Continuation?
        /// How the request ended, when it ended before anyone waited for its head.
        var ended: (any Error)?
    }

    private let state = Mutex(State())

    /// Waits for the head with `continuation`, which is resumed at once if the request has already ended.
    func awaitHead(_ continuation: CheckedContinuation<DownloadResponse, any Error>) {
        let ended = state.withLock { state -> (any Error)? in
            if let ended = state.ended { return ended }
            state.head = continuation
            return nil
        }
        if let ended { continuation.resume(throwing: ended) }
    }

    /// A redirect comes back as it is, for the download to judge.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            state.withLock { $0.head.take() }?.resume(throwing: URLError(.badServerResponse))
            return .cancel
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        let (body, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.onTermination = { _ in dataTask.cancel() }
        let head = state.withLock { state in
            state.body = continuation
            return state.head.take()
        }
        head?.resume(returning: DownloadResponse(status: http.statusCode, headers: headers, body: body))
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = state.withLock { $0.body }?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let ending = error ?? URLError(.badServerResponse)
        let (head, body) = state.withLock { state in
            let waiting = (state.head.take(), state.body.take())
            if waiting.0 == nil && waiting.1 == nil { state.ended = ending }
            return waiting
        }
        head?.resume(throwing: ending)
        if let error { body?.finish(throwing: error) } else { body?.finish() }
    }
}
