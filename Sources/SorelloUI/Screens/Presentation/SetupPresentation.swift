import Foundation

// Setup's steps and the buttons each one offers for the state the permissions are in
// (ARCHITECTURE.md, section 8, "Windows").

/// The steps of setup, in order. The model's step is in a setup only when the model was not on the Mac as it
/// opened, so a setup has the steps `steps(includingModel:)` gives it, and moves through those.
nonisolated public enum SetupStep: Int, CaseIterable, Sendable {
    case welcome
    /// Get the speech model.
    case model
    case microphone
    case accessibility
    case shortcut
    case test

    /// Every step, without the model's unless `includingModel`.
    public static func steps(includingModel: Bool) -> [SetupStep] {
        allCases.filter { includingModel || $0 != .model }
    }

    /// The step after this one among `steps`; nil after the last.
    public func next(in steps: [SetupStep]) -> SetupStep? {
        steps.firstIndex(of: self).flatMap { steps.indices.contains($0 + 1) ? steps[$0 + 1] : nil }
    }

    /// The step before this one among `steps`; nil before the first.
    public func previous(in steps: [SetupStep]) -> SetupStep? {
        steps.firstIndex(of: self).flatMap { $0 > 0 ? steps[$0 - 1] : nil }
    }

    /// "Step 2 of 6", for VoiceOver.
    public func spokenPosition(in steps: [SetupStep]) -> String {
        let position = (steps.firstIndex(of: self) ?? 0) + 1
        return String(localized: "Step \(position) of \(steps.count)")
    }
}

/// What a setup button does.
nonisolated public enum SetupAction: Equatable, Sendable {
    /// Go to the next step.
    case advance
    /// Start the speech model's download, or go on with it after it stopped.
    case downloadModel
    /// Ask for the microphone; the system shows its prompt.
    case requestMicrophone
    case openMicrophoneSettings
    /// Open System Settings with the card to drag into the Accessibility list.
    case openAccessibilitySettings
    /// Close setup.
    case finish
}

/// A setup button: its title and what it does.
nonisolated public struct SetupButton: Equatable, Sendable {
    /// The button's words.
    public var title: String
    /// What it does.
    public var action: SetupAction

    /// A button titled `title` that does `action`.
    public init(_ title: String, _ action: SetupAction) {
        self.title = title
        self.action = action
    }
}

/// The main button of a step, and the quieter one beside it, if any.
nonisolated public struct SetupButtons: Equatable, Sendable {
    /// The step's main action, on the island's surface.
    public var primary: SetupButton
    /// A quieter way on, beside it.
    public var secondary: SetupButton?

    /// Every step can be left without granting anything: a permission that is missing is offered again from the
    /// General screen, and the app works as far as it can without it.
    /// Once the model's download has started, the way on is Continue: it goes on behind the later steps.
    public static func forStep(_ step: SetupStep, microphone: MicrophoneStatus, accessibility: AccessibilityStatus,
                               model: ModelStatus = .ready) -> SetupButtons {
        let next = SetupButton(String(localized: "Continue"), .advance)
        let later = SetupButton(String(localized: "Not Now"), .advance)
        switch step {
        case .welcome:
            return SetupButtons(primary: SetupButton(String(localized: "Get Started"), .advance))
        case .model:
            switch model {
            case .notDownloaded(.notStarted):
                return SetupButtons(primary: SetupButton(String(localized: "Download"), .downloadModel),
                                    secondary: later)
            case .notDownloaded(.failed):
                return SetupButtons(primary: SetupButton(String(localized: "Try Again"), .downloadModel),
                                    secondary: later)
            case .notDownloaded(.downloading), .notDownloaded(.unavailable), .preparing, .ready, .failed:
                return SetupButtons(primary: next)
            }
        case .microphone:
            switch microphone {
            case .granted: return SetupButtons(primary: next)
            case .notDetermined:
                return SetupButtons(primary: SetupButton(String(localized: "Allow Microphone"), .requestMicrophone),
                                    secondary: later)
            case .denied:
                return SetupButtons(primary: SetupButton(String(localized: "Open System Settings"),
                                                         .openMicrophoneSettings),
                                    secondary: later)
            }
        case .accessibility:
            switch accessibility {
            case .granted: return SetupButtons(primary: next)
            case .missing:
                return SetupButtons(primary: SetupButton(String(localized: "Open System Settings"),
                                                         .openAccessibilitySettings),
                                    secondary: later)
            }
        case .shortcut:
            return SetupButtons(primary: next)
        case .test:
            return SetupButtons(primary: SetupButton(String(localized: "Done"), .finish))
        }
    }

    /// A step's buttons.
    public init(primary: SetupButton, secondary: SetupButton? = nil) {
        self.primary = primary
        self.secondary = secondary
    }
}

/// Setup's sentences that depend on state.
nonisolated public enum SetupCopy {
    /// The model step's one sentence: what is downloaded, how large it is, where from, and that nothing said to the
    /// app is ever sent anywhere.
    /// With no build for this Mac there is nothing to download and `size` is 0: then it promises neither a download
    /// nor a size.
    public static func modelLine(appName: String, size: Int64) -> String {
        guard size > 0 else {
            return String(localized: "\(appName) recognises speech on this Mac, with a model of its own. Nothing you say is ever sent anywhere.",
                          comment: "Setup: the app's name, when there is no model to download for this Mac")
        }
        return String(localized: "\(appName) recognises speech on this Mac, with a model it downloads once from Hugging Face. It is \(ModelSize.words(size)). Nothing you say is ever sent anywhere.",
                      comment: "Setup: the app's name, then the model's size, such as 138 MB")
    }

    /// What the live test waits for while the model is not on this Mac; nil once it is.
    public static func testWaiting(for model: ModelStatus) -> String? {
        switch model {
        case .notDownloaded(.downloading(let received, let size)):
            String(localized: "The speech model is still downloading, \(ModelSize.progress(received: received, of: size)). Try it once it has arrived.",
                   comment: "Setup's test: how much of the model has arrived, such as 62 MB of 138 MB")
        case .notDownloaded(.notStarted), .notDownloaded(.failed):
            String(localized: "The speech model isn’t downloaded yet. Download it to try dictating here.")
        case .notDownloaded(.unavailable): ModelDownloadWords.unavailable
        case .preparing, .ready, .failed: nil
        }
    }

    /// The live test's instruction, naming the Hold to Talk shortcut: "Hold fn and say something. Your words appear
    /// here."
    public static func testInstruction(hold: KeyCombo) -> String {
        String(localized: "Hold \(hold.inlineLabel) and say something. Your words appear here.")
    }
}
