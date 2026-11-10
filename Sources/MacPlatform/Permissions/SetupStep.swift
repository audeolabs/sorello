/// The steps of Setup, in order (ARCHITECTURE.md, section 8, "Windows"): welcome, microphone, Accessibility, the
/// shortcut, and a live test.
public enum SetupStep: Int, CaseIterable, Sendable {
    case welcome, microphone, accessibility, shortcut, test

    /// The step after this one; the last step has none after it and stays put.
    public var next: SetupStep { SetupStep(rawValue: rawValue + 1) ?? self }
    /// The step before this one; the first stays put.
    public var previous: SetupStep { SetupStep(rawValue: rawValue - 1) ?? self }
}
