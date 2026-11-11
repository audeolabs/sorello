import Foundation
import Testing
@testable import SpeechEngine

/// What carries a request in the app, without a connection: the request is never started, and the receiver is told
/// how it ended as URLSession would tell it.
struct DownloadReceiverTests {
    /// A request cancelled at once can end before anyone waits for its head; the end is kept for the waiter, so the
    /// download never waits forever.
    @Test func anEndThatComesBeforeTheWaitIsHandedToIt() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try #require(URL(string: "https://models.example.com/resolve/0123/bundle.json")))
        let receiver = DownloadReceiver()
        receiver.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        let outcome = await within(2) { () -> String in
            do {
                _ = try await withCheckedThrowingContinuation { receiver.awaitHead($0) }
                return "head"
            } catch {
                return (error as? URLError)?.code == .cancelled ? "cancelled" : "other"
            }
        }
        #expect(outcome == "cancelled")
    }
}
