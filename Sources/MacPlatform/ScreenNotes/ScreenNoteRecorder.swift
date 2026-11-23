import AppKit
import AVFoundation
import CoreMedia
import DictationCore
import Foundation
@preconcurrency import ScreenCaptureKit
import SystemCompat

/// A display a note records: its identifier, its frame in the global AppKit space (points, from the bottom left of
/// the main screen) and its scale.
public struct NoteDisplay: Sendable, Equatable {
    public var id: CGDirectDisplayID
    public var frame: CGRect
    public var scale: CGFloat
    /// Whether it takes touch, so a finger can draw on it.
    public var takesTouch: Bool

    public init(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat, takesTouch: Bool = false) {
        self.id = id
        self.frame = frame
        self.scale = scale
        self.takesTouch = takesTouch
    }

    /// The display the pointer is on now, or the main one.
    @MainActor
    public static func underPointer() -> NoteDisplay? {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        var takesTouch = false
        if #available(macOS 27, *) { takesTouch = screen.touchCapabilities.contains(.multiTouch) }
        return NoteDisplay(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor,
                           takesTouch: takesTouch)
    }
}

/// Why a note's recording could not start or did not finish. Content-free.
public enum ScreenRecordingFailure: Error, Sendable, Equatable {
    /// Screen Recording is not granted, or the system refused the stream.
    case notPermitted
    /// The display is not there any more.
    case displayGone
    /// The stream or the file failed.
    case failed
}

/// Records one display into a movie with ScreenCaptureKit (ARCHITECTURE.md, section 14, "Recording"): the whole
/// display at most 2560 pixels on its long edge, up to 30 frames a second, with the pointer, without this app's own
/// windows, and with the microphone when asked.
public struct ScreenNoteRecorder: Sendable {
    /// The longest edge of the recording, in pixels.
    public static let longestEdge: Double = 2560

    public init() {}

    /// Starts recording `display` into `file`, a `.mov` that must not exist yet. With `microphone`, the narration is
    /// recorded into the same file from that device, or from the system default when it is nil and `narrate` is set.
    /// Returns once the file has started; throws if it does not within 5 s.
    public func start(display: NoteDisplay, file: URL, narrate: Bool, microphone: String?) async throws(ScreenRecordingFailure)
        -> ScreenNoteRecording {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw .notPermitted
        }
        guard let target = content.displays.first(where: { $0.displayID == display.id }) else { throw .displayGone }
        // A note cancelled while the content was read never starts the stream.
        guard !Task.isCancelled else { throw .failed }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        // The pill and the ink overlay are left out through the app; the overlay is also never shared.
        if own.isEmpty { Diagnostics.record("screenNote.ownWindowsNotFound") }
        let filter = SCContentFilter(display: target, excludingApplications: own, exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        let width = Double(target.width) * Double(display.scale), height = Double(target.height) * Double(display.scale)
        let factor = min(1, Self.longestEdge / max(width, height, 1))
        configuration.width = Int((width * factor / 2).rounded()) * 2
        configuration.height = Int((height * factor / 2).rounded()) * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = narrate
        if narrate, let microphone { configuration.microphoneCaptureDeviceID = microphone }

        let recording = ScreenNoteRecording(file: file, display: display)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: recording)
        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = file
        outputConfiguration.outputFileType = .mov
        outputConfiguration.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: recording)
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
        } catch {
            throw .notPermitted
        }
        guard !Task.isCancelled else {
            try? await stream.stopCapture()
            throw .failed
        }
        recording.attach(stream)
        guard await recording.waitUntilStarted(timeout: 5) else {
            await recording.cancel()
            throw .failed
        }
        return recording
    }
}

/// One note's recording in progress.
// Safe: every mutable field is behind `state`, a Mutex; the stream itself is only started, stopped and released.
public final class ScreenNoteRecording: NSObject, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    /// How long a stop may take to finish the movie before the movie is given up.
    static let finishTimeout: TimeInterval = 5

    public let file: URL
    public let display: NoteDisplay

    private struct State {
        var stream: SCStream?
        /// `systemUptime` when the file started.
        var startedAt: TimeInterval?
        var started: [CheckedContinuation<Bool, Never>] = []
        var finished: [CheckedContinuation<Bool, Never>] = []
        var didFinish: Bool?
        var stopping = false
        /// The stream or its file stopped by itself; told to the handler once, whenever it is set.
        var interrupted = false
        var told = false
        var onInterrupted: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    init(file: URL, display: NoteDisplay) {
        self.file = file
        self.display = display
    }

    func attach(_ stream: SCStream) { state.withLock { $0.stream = stream } }

    /// `ProcessInfo.systemUptime` when the movie's first moment was recorded, the zero of the note's times.
    public var startedAt: TimeInterval? { state.withLock { $0.startedAt } }

    /// Told once if the stream or its file stops by itself (the display went away, the system stopped it, the file
    /// failed): the note should finish with what was recorded. An interruption before the handler is given is told
    /// as it is given.
    public func onInterrupted(_ handler: @escaping @Sendable () -> Void) {
        let tellNow = state.withLock { state -> Bool in
            state.onInterrupted = handler
            guard state.interrupted, !state.told else { return false }
            state.told = true
            return true
        }
        if tellNow { handler() }
    }

    private func interrupt() {
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.stopping, !state.interrupted else { return nil }
            state.interrupted = true
            guard let handler = state.onInterrupted else { return nil }
            state.told = true
            return handler
        }
        handler?()
    }

    func waitUntilStarted(timeout: TimeInterval) async -> Bool {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.resumeStarted(false)
        }
        defer { timer.cancel() }
        // A cancelled caller stops waiting at once, and `start` then stops the stream before it returns.
        let started = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Bool? in
                    if Task.isCancelled { return false }
                    if state.startedAt != nil { return true }
                    if state.didFinish != nil { return false }
                    state.started.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            resumeStarted(false)
        }
        return started && !Task.isCancelled
    }

    private func resumeStarted(_ value: Bool) {
        let waiting = state.withLock { state -> [CheckedContinuation<Bool, Never>] in
            defer { state.started = [] }
            return state.started
        }
        for continuation in waiting { continuation.resume(returning: value) }
    }

    /// Stops the stream and returns once the movie is complete. Throws if the file could not be finished, including
    /// when the stop does not finish it within `finishTimeout`.
    public func finish() async throws(ScreenRecordingFailure) {
        let stream = state.withLock { state -> SCStream? in
            state.stopping = true
            return state.stream
        }
        do {
            try await stream?.stopCapture()
        } catch {
            Diagnostics.record("screenNote.stopFailed")
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishTimeout))
            self?.ended(successfully: false)
        }
        defer { timer.cancel() }
        let completed = await withCheckedContinuation { continuation in
            let done = state.withLock { state -> Bool? in
                if let done = state.didFinish { return done }
                state.finished.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
        state.withLock { $0.stream = nil }
        guard completed else { throw .failed }
    }

    /// Stops the stream; whatever was written is the caller's to delete.
    public func cancel() async {
        let stream = state.withLock { state -> SCStream? in
            state.stopping = true
            defer { state.stream = nil }
            return state.stream
        }
        try? await stream?.stopCapture()
        resumeStarted(false)
    }

    // MARK: - ScreenCaptureKit

    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.startedAt = $0.startedAt ?? now }
        resumeStarted(true)
    }

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Diagnostics.record("screenNote.recordingFailed")
        interrupt()
        ended(successfully: false)
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        ended(successfully: true)
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Diagnostics.record("screenNote.streamStopped")
        interrupt()
    }

    /// The movie is finished, or will never be: every waiter hears it once, with the first answer.
    private func ended(successfully: Bool) {
        let (waiting, done) = state.withLock { state -> ([CheckedContinuation<Bool, Never>], Bool) in
            if state.didFinish == nil { state.didFinish = successfully }
            defer { state.finished = [] }
            return (state.finished, state.didFinish ?? successfully)
        }
        for continuation in waiting { continuation.resume(returning: done) }
        resumeStarted(false)
    }
}
