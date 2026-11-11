import Foundation

/// The menu-bar item's menu in each state, as text for the snapshot tool (ARCHITECTURE.md, section 11). The system
/// draws the menu, so no picture of it can be rendered off screen; its rows are reviewed as text beside the pictures.
public enum StatusMenuSnapshots {
    /// Each state's file name, without extension, and the menu's rows as text, in the order the tool writes them.
    public static var texts: [(name: String, text: String)] {
        // Copy Last Dictation is available in three states and unavailable in the others, so the listings show both.
        let states: [(String, AppStatus, Bool)] = [
            ("ready", .sampleReady, true),
            ("preparing", AppStatus(model: .preparing, microphone: .granted, accessibility: .granted), false),
            ("microphone-needed", AppStatus(model: .ready, microphone: .denied, accessibility: .granted), false),
            ("accessibility-needed", AppStatus(model: .ready, microphone: .granted, accessibility: .missing), true),
            ("model-failed", AppStatus(model: .failed(.couldNotLoad), microphone: .granted, accessibility: .granted),
             false),
            ("paused", AppStatus(model: .ready, microphone: .granted, accessibility: .granted, shortcutsPaused: true),
             true),
            ("model-not-downloaded", AppStatus(model: .sampleNotDownloaded, microphone: .granted,
                                               accessibility: .granted), false),
            ("model-downloading", AppStatus(model: .sampleDownloading, microphone: .granted, accessibility: .granted),
             false),
            ("model-no-build", AppStatus(model: .sampleNoBuild, microphone: .granted, accessibility: .granted), false),
        ]
        var texts = states.map { name, status, copyable in
            ("menu-\(name)", StatusMenuController(model: .sample(status: status, hasLastDictation: copyable)).text)
        }
        // A build with an update feed has the update row, in each of its forms; the states above have none.
        for (name, updates) in [("updates", UpdateRowState.checkForUpdates(isEnabled: true)),
                                ("updates-checking", .checkForUpdates(isEnabled: false)),
                                ("update-available", .updateAvailable)] {
            let model = StatusMenuModel.sample(hasLastDictation: true)
            model.updates = updates
            texts.append(("menu-\(name)", StatusMenuController(model: model).text))
        }
        return texts
    }
}
