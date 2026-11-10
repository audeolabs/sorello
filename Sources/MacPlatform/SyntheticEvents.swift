/// The mark on every keyboard event Sorello posts (ARCHITECTURE.md, section 6, "Shortcuts"). The inserter sets it
/// as the event's source user data; the shortcut tap ignores any event that carries it, so Sorello's own Command-V
/// can never trigger or cancel a dictation.
public enum SyntheticEvents {
    /// "SORELLO" in ASCII.
    public static let tag: Int64 = 0x53_4F_52_45_4C_4C_4F
}
