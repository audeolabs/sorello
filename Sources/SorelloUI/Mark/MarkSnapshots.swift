import AppKit
import DesignCore
import SwiftUI

/// The mark's scenes: the mark itself, the menu-bar icon on a light and a dark bar, the app icon, plain and the
/// nightly's, and the iPhone app's icon, plain and the development build's, as its files hold it and as an iPhone
/// shows it.
enum MarkSnapshots {
    static var scenes: [SnapshotScene] {
        [
            SnapshotScene(name: "mark", size: CGSize(width: 320, height: 140)) {
                SorelloMarkView().frame(width: 200, height: 60)
            },
            menuBar(name: "mark-menu-bar-light", bar: RGB(hex: 0xECECEE), ink: .black),
            menuBar(name: "mark-menu-bar-dark", bar: RGB(hex: 0x1E1E20), ink: .white),
            // The app icon for review, over black. Resources/AppIcon.icns, and Resources/AppIcon-Nightly.icns with the
            // nightly's stars, are built from the same view with its corners transparent; to regenerate them on a Mac:
            //   mkdir -p build
            //   swift run SorelloSnapshots --icon build/AppIcon-1024.png
            //   swift run SorelloSnapshots --nightly-icon build/AppIcon-Nightly-1024.png
            //   for icon in AppIcon AppIcon-Nightly; do
            //     mkdir -p build/$icon.iconset
            //     for s in 16 32 128 256 512; do
            //       sips -z $s $s build/$icon-1024.png --out build/$icon.iconset/icon_${s}x${s}.png
            //       sips -z $((s*2)) $((s*2)) build/$icon-1024.png --out build/$icon.iconset/icon_${s}x${s}@2x.png
            //     done
            //   done
            //   # At 32 pixels and under the stars would be specks of brown, so there the nightly's is the plain icon.
            //   cp build/AppIcon.iconset/icon_16x16.png build/AppIcon.iconset/icon_16x16@2x.png \
            //     build/AppIcon.iconset/icon_32x32.png build/AppIcon-Nightly.iconset/
            //   iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
            //   iconutil -c icns build/AppIcon-Nightly.iconset -o Resources/AppIcon-Nightly.icns
            SnapshotScene(name: "mark-app-icon", size: CGSize(width: 512, height: 512), background: RGB(0, 0, 0)) {
                AppIconView().frame(width: 512, height: 512)
            },
            // Sorello Nightly's icon beside the plain one, large and at the Dock's usual size, on a strip of dark Dock.
            SnapshotScene(name: "mark-app-icon-nightly", size: CGSize(width: 572, height: 376),
                          background: RGB(hex: 0x1E1E20)) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach([AppIconView.Variant.plain, .nightly], id: \.self) { variant in
                        VStack(spacing: 16) {
                            AppIconView(variant).frame(width: 256, height: 256)
                            AppIconView(variant).frame(width: 64, height: 64)
                        }
                    }
                }
            },
            // The iPhone app's icons at full size, 1024 pixels, as iOS/Resources holds them: the App Store build's and
            // the development build's, with the stars. To regenerate the files on a Mac (iOS/Resources/ICON.md):
            //   swift run SorelloSnapshots --ios-icon iOS/Resources/AppIcon-Source.png
            //   swift run SorelloSnapshots --ios-dev-icon iOS/Resources/AppIcon-Dev-Source.png
            SnapshotScene(name: "mark-iphone-icon", size: CGSize(width: 512, height: 512)) {
                AppIconView(.iPhone).frame(width: 512, height: 512)
            },
            SnapshotScene(name: "mark-iphone-icon-development", size: CGSize(width: 512, height: 512)) {
                AppIconView(.iPhoneDevelopment).frame(width: 512, height: 512)
            },
            // Both as an iPhone shows them, cut to its shape, on the dark and the light Settings background.
            iPhoneSizes(name: "mark-iphone-icon-sizes-dark", background: RGB(0, 0, 0)),
            iPhoneSizes(name: "mark-iphone-icon-sizes-light", background: RGB(hex: 0xF2F2F7)),
        ]
    }

    /// The iPhone app's icons, the App Store build's above the development build's, cut to the shape iOS cuts an icon
    /// to, at the sizes an iPhone draws them at three pixels a point: 180 pixels on the Home Screen, 120 in Spotlight
    /// and 87 in Settings. The snapshot tool renders two pixels a point, so each is half that many points.
    static func iPhoneSizes(name: String, background: RGB) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: 320, height: 240), background: background) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach([AppIconView.Variant.iPhone, .iPhoneDevelopment], id: \.self) { variant in
                    HStack(alignment: .center, spacing: 24) {
                        ForEach([180.0, 120, 87], id: \.self) { pixels in
                            let side = pixels / 2
                            AppIconView(variant)
                                .frame(width: side, height: side)
                                .clipShape(RoundedRectangle(cornerRadius: AppIconGeometry.iOSCornerRadius
                                                                / AppIconGeometry.canvas * side,
                                                            style: .continuous))
                        }
                    }
                }
            }
        }
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
