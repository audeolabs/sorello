import Foundation

// Setup's steps and the buttons each one offers for the state the permissions are in
// (ARCHITECTURE.md, section 8, "Windows").

/// The steps of setup, in order.
nonisolated public enum SetupStep: Int, CaseIterable, Sendable {
    case welcome
    case microphone
    case accessibility
    case shortcut
    case test

    /// The step after this one; nil after the last.
    public var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    /// The step before this one; nil before the first.
    public var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }

    /// "Step 2 of 5", for VoiceOver.
    public var spokenPosition: String {
        String(localized: "Step \(rawValue + 1) of \(SetupStep.allCases.count)")
    }
}

/// What a setup button does.
nonisolated public enum SetupAction: Equatable, Sendable {
    /// Go to the next step.
    case advance
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
    public static func forStep(_ step: SetupStep, microphone: MicrophoneStatus,
                               accessibility: AccessibilityStatus) -> SetupButtons {
        let next = SetupButton(String(localized: "Continue"), .advance)
        let later = SetupButton(String(localized: "Not Now"), .advance)
        switch step {
        case .welcome:
            return SetupButtons(primary: SetupButton(String(localized: "Get Started"), .advance))
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
    /// The live test's instruction, naming the Hold to Talk shortcut: "Hold fn and say something. Your words appear
    /// here."
    public static func testInstruction(hold: KeyCombo) -> String {
        String(localized: "Hold \(hold.inlineLabel) and say something. Your words appear here.")
    }
}
