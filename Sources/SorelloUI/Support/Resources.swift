import AppKit
import CoreText

/// Files the UI loads at run time: the display font and images. In the app they are in the bundle's Resources
/// directory; in a build tree (tests, the snapshot tool) they are in the repository's `Resources` directory, or
/// wherever `SORELLO_RESOURCES` points.
public enum Resources {
    public static let displayFontName = "GeistSerif-Regular"

    public static var directory: URL? {
        let manager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SORELLO_RESOURCES"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let bundled = Bundle.main.resourceURL, manager.fileExists(atPath: bundled.appendingPathComponent("Fonts").path) {
            return bundled
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

    public static var hasDisplayFont: Bool { NSFont(name: displayFontName, size: 17) != nil }
}
