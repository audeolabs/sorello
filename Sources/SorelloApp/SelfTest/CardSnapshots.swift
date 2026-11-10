import AppKit
import DesignCore
import MacPlatform
import SorelloUI

/// The Accessibility drag card for `Sorello --snapshots`, in Sorello's colours, on each of its surfaces: Liquid
/// Glass as macOS 26 and later draw it, and the blurred material macOS 15 draws, forced on this Mac
/// (ARCHITECTURE.md, sections 6 and 11). Each is drawn over a light System Settings window, the background that shows
/// the frost and the shadows best, and names the Accessibility pane as that system names it.
@MainActor
enum CardSnapshots {
    static var scenes: [SnapshotScene] {
        [scene(name: "app-permission-card-glass", paneOnMacOS: 27, forcesOlderSurface: false),
         scene(name: "app-permission-card-blurred", paneOnMacOS: 15, forcesOlderSurface: true)]
    }

    /// System Settings' window background in the light appearance.
    private static let settingsBackground = RGB(0.93, 0.93, 0.93)

    private static func scene(name: String, paneOnMacOS version: Int, forcesOlderSurface: Bool) -> SnapshotScene {
        let card = picture(paneOnMacOS: version, forcesOlderSurface: forcesOlderSurface)
        return SnapshotScene(name: name, size: card.frame.size, background: settingsBackground) {
            picture(paneOnMacOS: version, forcesOlderSurface: forcesOlderSurface)
        }
    }

    private static func picture(paneOnMacOS version: Int, forcesOlderSurface: Bool) -> NSView {
        PermissionPanel.picture(style: .sorello,
                                paneTitle: PrivacyPermission.accessibility.settingsTitle(macOSMajorVersion: version),
                                appName: "Sorello", icon: icon, forcesOlderSurface: forcesOlderSurface)
    }

    /// The app's icon, drawn from the mark, so the picture does not depend on where the executable runs from.
    private static var icon: NSImage {
        guard let data = AppIconView.png(pixels: 128), let image = NSImage(data: data) else { return NSImage() }
        image.size = NSSize(width: 64, height: 64)
        return image
    }
}
