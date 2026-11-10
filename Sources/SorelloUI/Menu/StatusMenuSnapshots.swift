import Foundation

/// The menu-bar item's menu in each state, as text for the snapshot tool (ARCHITECTURE.md, section 11). The system
/// draws the menu, so no picture of it can be rendered off screen; its rows are reviewed as text beside the pictures.
public enum StatusMenuSnapshots {
    /// Each state's file name, without extension, and the menu's rows as text, in the order the tool writes them.
    public static var texts: [(name: String, text: String)] {
        let states: [(String, AppStatus, String?)] = [
            ("ready", .sampleReady, StatusMenuModel.sample().lastDictation),
            ("preparing", AppStatus(model: .preparing, microphone: .granted, accessibility: .granted), nil),
            ("microphone-needed", AppStatus(model: .ready, microphone: .denied, accessibility: .granted), nil),
            ("accessibility-needed", AppStatus(model: .ready, microphone: .granted, accessibility: .missing),
             "Pack my box with five dozen liquor jugs."),
            ("model-failed", AppStatus(model: .failed(.couldNotLoad), microphone: .granted, accessibility: .granted),
             nil),
            ("paused", AppStatus(model: .ready, microphone: .granted, accessibility: .granted, shortcutsPaused: true),
             "How vexingly quick daft zebras jump."),
        ]
        return states.map { name, status, last in
            ("menu-\(name)", StatusMenuController(model: .sample(status: status, lastDictation: last)).text)
        }
    }
}
