import AppKit
import Foundation
import MacPlatform
import ScreenNotes
import SorelloUI

// What screen notes need from the Mac (ARCHITECTURE.md, section 14), behind protocols, so the coordinator is tested
// with fakes: no test records the screen, reads the pointer, draws over the screen or writes the pasteboard.
// `ScreenNotePlatform.system()` gives the real adapters.

/// Screen Recording, read without asking; `request` asks.
protocol ScreenPermissionChecking: Sendable {
    var isGranted: Bool { get }
    @discardableResult func request() -> Bool
    @MainActor func openSettings()
}

extension ScreenRecordingPermission: ScreenPermissionChecking {}

/// Starts a note's recording.
protocol NoteRecorderStarting: Sendable {
    func startRecording(display: NoteDisplay, file: URL, narrate: Bool, microphone: String?)
        async throws(ScreenRecordingFailure) -> any NoteRecordingSession
}

extension ScreenNoteRecorder: NoteRecorderStarting {
    func startRecording(display: NoteDisplay, file: URL, narrate: Bool, microphone: String?)
        async throws(ScreenRecordingFailure) -> any NoteRecordingSession {
        try await start(display: display, file: file, narrate: narrate, microphone: microphone)
    }
}

/// A note's recording in progress.
protocol NoteRecordingSession: AnyObject, Sendable {
    /// The note's zero on the session clock's timeline.
    var startedAt: TimeInterval? { get }
    func onInterrupted(_ handler: @escaping @Sendable () -> Void)
    func finish() async throws(ScreenRecordingFailure)
    func cancel() async
}

extension ScreenNoteRecording: NoteRecordingSession {}

/// The pointer, ⇧ and the left button while a note records.
@MainActor
protocol PointerWatching: AnyObject {
    func start(display: NoteDisplay, startedAt: TimeInterval, handler: @escaping @MainActor (PointerEvent) -> Void)
    func stop()
}

extension PointerWatcher: PointerWatching {}

/// The ink overlay.
@MainActor
protocol InkPresenting: AnyObject {
    /// With `touch`, the overlay takes fingers on the display and reports them there.
    func show(on frame: CGRect, touch: (@MainActor (InkTouch) -> Void)?)
    func update(_ scene: InkScene)
    func hide()
}

extension InkOverlayController: InkPresenting {}

/// Reads a note's movie and makes its images.
protocol NoteRendering: Sendable {
    func inspect(_ movie: URL) async throws(NoteRenderingFailure) -> NoteMovie
    func render(_ note: ScreenNote, movie: URL, folder: URL) async throws(NoteRenderingFailure)
}

extension NoteRenderer: NoteRendering {}

/// Every adapter screen notes use.
@MainActor
struct ScreenNotePlatform {
    var permission: any ScreenPermissionChecking
    var displayUnderPointer: @MainActor () -> NoteDisplay?
    var recorder: any NoteRecorderStarting
    var pointer: any PointerWatching
    /// Made with the clock its scenes' times are on: seconds from the note's start.
    var ink: (_ clock: @escaping @MainActor () -> TimeInterval) -> any InkPresenting
    var renderer: any NoteRendering
    /// Puts the summary, as text, and the contact sheet, as a PNG, on the clipboard as one item.
    var copy: @MainActor (_ summary: String, _ contactSheet: URL) -> Void
    /// Shows a folder in the Finder.
    var reveal: @MainActor (URL) -> Void

    static func system() -> ScreenNotePlatform {
        ScreenNotePlatform(
            permission: ScreenRecordingPermission(),
            displayUnderPointer: { NoteDisplay.underPointer() },
            recorder: ScreenNoteRecorder(),
            pointer: PointerWatcher(),
            ink: { clock in InkOverlayController(clock: clock) },
            renderer: NoteRenderer(),
            copy: { summary, sheet in
                let item = NSPasteboardItem()
                item.setString(summary, forType: .string)
                if let png = try? Data(contentsOf: sheet) { item.setData(png, forType: .png) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item])
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
    }
}
