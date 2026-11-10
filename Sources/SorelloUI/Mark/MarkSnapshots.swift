import AppKit
import DesignCore
import SwiftUI

/// The mark's scenes: the mark itself, the menu-bar icon on a light and a dark bar, and the app icon.
enum MarkSnapshots {
    static var scenes: [SnapshotScene] {
        [
            SnapshotScene(name: "mark", size: CGSize(width: 320, height: 140)) {
                SorelloMarkView().frame(width: 200, height: 60)
            },
            menuBar(name: "mark-menu-bar-light", bar: RGB(hex: 0xECECEE), ink: .black),
            menuBar(name: "mark-menu-bar-dark", bar: RGB(hex: 0x1E1E20), ink: .white),
            // The app icon for review, over black. Resources/AppIcon.icns is built from the same view with its
            // corners transparent; to regenerate it on a Mac:
            //   swift run SorelloSnapshots --icon build/AppIcon-1024.png
            //   mkdir -p build/AppIcon.iconset
            //   for s in 16 32 128 256 512; do
            //     sips -z $s $s build/AppIcon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png
            //     sips -z $((s*2)) $((s*2)) build/AppIcon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png
            //   done
            //   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
            SnapshotScene(name: "mark-app-icon", size: CGSize(width: 512, height: 512), background: RGB(0, 0, 0)) {
                AppIconView().frame(width: 512, height: 512)
            },
        ]
    }

    /// The template icon at its real size on a strip of menu bar, tinted as the system tints it.
    static func menuBar(name: String, bar: RGB, ink: NSColor) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: 120, height: 30), background: bar) {
            let icon = SorelloMarkImages.menuBarIcon()
            return Image(nsImage: icon).renderingMode(.template).foregroundStyle(Color(nsColor: ink))
                .frame(width: icon.size.width, height: icon.size.height)
        }
    }
}
