import AppKit
import SorelloUI

// Renders every snapshot scene to a PNG file (ARCHITECTURE.md, section 11).
//   SorelloSnapshots <output-directory> [text the scene's name must contain]
// Writes the app icon as a 1024 px PNG with transparent corners, for Resources/AppIcon.icns:
//   SorelloSnapshots --icon <file.png>

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first else {
    print("usage: SorelloSnapshots <output-directory> [name-filter] | --icon <file.png>")
    exit(64)
}

let application = NSApplication.shared
Resources.registerFonts()

switch first {
case "--icon":
    application.setActivationPolicy(.prohibited)
    guard let path = arguments.dropFirst().first, let data = AppIconView.png() else {
        print("usage: SorelloSnapshots --icon <file.png>")
        exit(64)
    }
    try data.write(to: URL(fileURLWithPath: path))
    print(path)
default:
    application.setActivationPolicy(.prohibited)
    let filter = arguments.dropFirst().first
    let directory = URL(fileURLWithPath: first, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var failures = 0
    for scene in SnapshotCatalog.all where filter.map({ scene.name.contains($0) }) ?? true {
        guard let data = SnapshotRenderer.png(of: scene) else {
            print("FAILED \(scene.name)")
            failures += 1
            continue
        }
        try data.write(to: directory.appendingPathComponent(scene.name + ".png"))
        print(scene.name)
    }
    exit(failures == 0 ? 0 : 1)
}
