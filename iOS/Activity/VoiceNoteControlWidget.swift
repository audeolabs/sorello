import AppIntents
import SwiftUI
import WidgetKit

/// The "Voice Note" control (ARCHITECTURE.md, "Voice Note control"): one button for the Action button, Control Center
/// and the Lock Screen, beside "Dictation Session". A button, not a toggle, for the session control's reason; the Live
/// Activity shows whether a note records.
struct VoiceNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        // Kept: iOS binds a control placed on the Action button or in Control Center to this kind.
        StaticControlConfiguration(kind: "VoiceNoteControl") {
            ControlWidgetButton(action: ToggleVoiceNoteIntent()) {
                Label("Voice Note", systemImage: "note.text")
            }
        }
        .displayName("Voice Note")
    }
}
