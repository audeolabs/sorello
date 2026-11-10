import AppKit
import CoreText

/// Files the UI loads at run time: the display font and images. In the app they are in the bundle's Resources
/// directory; in a build tree (tests, the snapshot tool) they are in the repository's `Resources` directory, or
/// wherever `SORELLO_RESOURCES` points.
public enum Resources {
    /// The PostScript name of the display face, Urbanist Medium, which ships as `Fonts/Urbanist-Medium.ttf`. Display
    /// text is set through `View.displayType(_:)`, which adds the tracking the face is set with.
    static let displayFontName = "Urbanist-Medium"

    public static var directory: URL? {
        let manager = FileManager.default
        // An app bundle loads only what it ships, so a missing resource shows up instead of being papered over by a
        // developer's checkout.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.resourceURL
        }
        if let override = ProcessInfo.processInfo.environment["SORELLO_RESOURCES"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        return manager.fileExists(atPath: repository.path) ? repository : nil
    }

    /// Registers the bundled fonts for this process. Call once at launch; without the font, display text falls back
    /// to the system font.
    @discardableResult
    public static func registerFonts() -> Bool {
        guard let fonts = directory?.appendingPathComponent("Fonts", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)
        else { return false }
        var registered = false
        for file in files where file.pathExtension.lowercased() == "ttf" || file.pathExtension.lowercased() == "otf" {
            if CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) { registered = true }
        }
        return registered
    }
}
