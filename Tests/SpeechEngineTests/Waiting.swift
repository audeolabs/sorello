import DictationCore
import Foundation
import Synchronization
import Testing
@testable import SpeechEngine

/// Runs `operation` and waits for it at most `seconds`. When it takes longer, an issue is recorded and nil returned,
/// so an engine that hangs fails its test instead of hanging the whole run. The operation is cancelled then, and
/// left to finish on its own. Cancelling the caller cancels the operation.
func within<T: Sendable>(_ seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation,
                         _ operation: @escaping @Sendable () async -> T) async -> T? {
    let result = Mutex<T?>(nil)
    let task = Task {
        let value = await operation()
        result.withLock { $0 = value }
    }
    let deadline = ContinuousClock.now + .seconds(seconds)
    return await withTaskCancellationHandler {
        while ContinuousClock.now < deadline {
            if let value = result.withLock({ $0 }) { return value }
            try? await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        Issue.record("Timed out after \(seconds) s", sourceLocation: sourceLocation)
        return nil
    } onCancel: {
        task.cancel()
    }
}

/// Finishes a stream within a time limit: its result, its failure, or nil when it hung.
func finish(_ stream: any SpeechStreaming, within seconds: Double = 10,
            sourceLocation: SourceLocation = #_sourceLocation) async -> Result<SpeechResult, SpeechFailure>? {
    await within(seconds, sourceLocation: sourceLocation) {
        do {
            return .success(try await stream.finish())
        } catch let failure as SpeechFailure {
            return .failure(failure)
        } catch {
            return .failure(.failed)
        }
    }
}

/// Transcribes a whole buffer within a time limit.
func transcribe(_ engine: SpeechEngine, _ samples: [Float], within seconds: Double = 10,
                sourceLocation: SourceLocation = #_sourceLocation) async -> Result<String, SpeechFailure>? {
    await within(seconds, sourceLocation: sourceLocation) {
        do throws(SpeechFailure) {
            return .success(try await engine.transcribe(samples))
        } catch {
            return .failure(error)
        }
    }
}

/// Prepares an engine within a time limit; true when it returned.
@discardableResult
func prepare(_ engine: SpeechEngine, within seconds: Double = 10,
             sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    await within(seconds, sourceLocation: sourceLocation) { await engine.prepare() } != nil
}

/// Every readiness value an engine reports, recorded from the moment it is made.
final class ReadinessLog: Sendable {
    private final class Values: Sendable {
        let list = Mutex<[EngineReadiness]>([])
    }

    private let values = Values()
    private let task: Task<Void, Never>

    init(_ engine: SpeechEngine) {
        let values = self.values
        let stream = engine.readiness()
        task = Task {
            for await readiness in stream { values.list.withLock { $0.append(readiness) } }
        }
    }

    deinit { task.cancel() }

    var all: [EngineReadiness] { values.list.withLock { $0 } }

    /// The values once there are `count` of them, or what there is after `seconds`.
    func first(_ count: Int, within seconds: Double = 5) async -> [EngineReadiness] {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while all.count < count && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return all
    }
}
