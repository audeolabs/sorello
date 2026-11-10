import AppKit
import SorelloUI

// Renders every snapshot scene to a PNG file (ARCHITECTURE.md, section 11).
//   SorelloSnapshots <output-directory> [text the scene's name must contain]

let arguments = Array(CommandLine.arguments.dropFirst())
guard let output = arguments.first else {
    print("usage: SorelloSnapshots <output-directory> [name-filter]")
    exit(64)
}
let filter = arguments.dropFirst().first

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Resources.registerFonts()

let directory = URL(fileURLWithPath: output, isDirectory: true)
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
