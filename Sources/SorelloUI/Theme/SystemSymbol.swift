/// System symbols whose names the system changed. A name the system does not have draws nothing, so each of these
/// gives the name the running system knows (ARCHITECTURE.md, section 15). Both names are literals, which is what
/// lets the tests check every symbol Sorello names against the system's own record.
public enum SystemSymbol {
    /// The Accessibility figure: "accessibility" from macOS 14, and before that the figure without its ring.
    public static var accessibility: String {
        if #available(macOS 14, *) { "accessibility" } else { "figure.arms.open" }
    }

    /// A battery three quarters full, for the pictures of a menu bar: renamed in macOS 14.
    public static var battery: String {
        if #available(macOS 14, *) { "battery.75percent" } else { "battery.75" }
    }
}
