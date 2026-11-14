import AppKit
import UniformTypeIdentifiers

/// The system's open and save panels for Transcribe File, each shown as a sheet on that window (ARCHITECTURE.md,
/// section 8, "Windows"). A window that already has a sheet gets no second one.
@MainActor
struct TranscribePanels {
    /// The Transcribe File window, once it has been made.
    let window: () -> NSWindow?

    /// The file picker, offering audio and video files, one at a time. `chosen` hears the file, if one is chosen.
    func chooseFile(_ chosen: @escaping @MainActor (URL) -> Void) {
        guard let window = window(), window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let file = panel.url else { return }
            MainActor.assumeIsolated { chosen(file) }
        }
    }

    /// The save panel, offering `name`, and then `text` written where the user chose, as plain UTF-8 text. If it
    /// cannot be written, a sheet says so; it never names the file or quotes the text.
    func save(_ text: String, name: String) {
        guard let window = window(), window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated {
                do {
                    try Data(text.utf8).write(to: destination, options: .atomic)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "The text couldn’t be saved")
                    alert.informativeText = String(localized: "Choose another place, or check there is room on the disk.")
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }
}
