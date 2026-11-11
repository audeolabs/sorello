import AppKit
import DesignCore
import SorelloUI

// Renders every snapshot scene to a PNG file, and writes the menu-bar item's menu in each state as a text file beside
// them, since the system draws the menu (ARCHITECTURE.md, section 11).
//   SorelloSnapshots <output-directory> [text the scene's or the menu state's name must contain]
// Shows the real pill on the real screen, cycling through its states with a synthetic voice, then exits; it prints
// the screen it read and the frames it used, to check the pill against the hardware by eye:
//   SorelloSnapshots --demo [seconds]
// Writes the app icon as a 1024 px PNG with transparent corners, for Resources/AppIcon.icns, or Sorello Nightly's, with
// its stars, for Resources/AppIcon-Nightly.icns (the recipe is in SorelloUI's MarkSnapshots.swift):
//   SorelloSnapshots --icon <file.png>
//   SorelloSnapshots --nightly-icon <file.png>
// Writes the iPhone app's icon as a 1024 px PNG, opaque to its edges, for iOS/Resources/AppIcon-Source.png, or its
// development build's, with the stars, for iOS/Resources/AppIcon-Dev-Source.png (iOS/Resources/ICON.md):
//   SorelloSnapshots --ios-icon <file.png>
//   SorelloSnapshots --ios-dev-icon <file.png>

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first else {
    print("usage: SorelloSnapshots <output-directory> [name-filter] | --demo [seconds] | --icon <file.png>"
        + " | --nightly-icon <file.png> | --ios-icon <file.png> | --ios-dev-icon <file.png>")
    exit(64)
}

/// The icon each icon flag writes.
let icons: [String: AppIconView.Variant] = [
    "--icon": .plain, "--nightly-icon": .nightly, "--ios-icon": .iPhone, "--ios-dev-icon": .iPhoneDevelopment,
]

let application = NSApplication.shared
Resources.registerFonts()

switch first {
case "--demo":
    application.setActivationPolicy(.accessory)
    let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 20
    let demo = PillDemo(seconds: max(seconds, 2))
    demo.start()
    application.run()
case let flag where icons[flag] != nil:
    application.setActivationPolicy(.prohibited)
    guard let variant = icons[flag], let path = arguments.dropFirst().first,
          let data = AppIconView.png(variant: variant)
    else {
        print("usage: SorelloSnapshots \(first) <file.png>")
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
    for (name, text) in StatusMenuSnapshots.texts where filter.map({ name.contains($0) }) ?? true {
        try text.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        print(name + ".txt")
    }
    exit(failures == 0 ? 0 : 1)
}

/// The live demo: the overlay on the screen with keyboard focus, a synthetic voice in the level feed, every state in
/// turn, then exit.
@MainActor
final class PillDemo {
    private let seconds: Double
    private let feed = LevelFeed()
    private let overlay: PillOverlayController
    private var capture: UInt64 = 0
    private var voiceTimer: Timer?
    private var phase = 0.0

    init(seconds: Double) {
        self.seconds = seconds
        overlay = PillOverlayController(levels: feed)
        overlay.onStop = { print("clicked: stop") }
        overlay.onCancel = { print("clicked: cancel") }
        overlay.onNoticeAction = { notice, action in print("clicked: notice \(notice) action \(action)") }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var states: [(String, PillDisplay)] {
        [
            ("listening, hold", .listening(.init(trigger: .hold, started: now))),
            ("listening, toggle", .listening(.init(trigger: .toggle, started: now))),
            ("listening, prompt style", .listening(.init(trigger: .hold, promptStyle: true, started: now))),
            ("waiting", .waiting(.transcribing)),
            ("waiting, preparing the model", .waiting(.preparingModel)),
            ("error notice", .notice(.init(id: 1, symbol: "exclamationmark.triangle.fill", tone: .error,
                                           text: "The microphone stopped. Nothing was lost."))),
            ("dictionary suggestion", .notice(.init(
                id: 2, symbol: "character.book.closed.fill", tone: .information,
                text: "Add \u{201C}Okonkwo\u{201D} to your dictionary?",
                actions: [.init(id: "add", title: "Add", isPrimary: true), .init(id: "later", title: "Not Now"),
                          .init(id: "never", title: "Don\u{2019}t Suggest")]))),
            ("dictionary suggestion, a long app name", .notice(.init(
                id: 3, symbol: "character.book.closed.fill", tone: .information,
                text: "Add \u{201C}Okonkwo\u{201D} to your dictionary?",
                actions: [.init(id: "add-app", title: "Add to Northwind Field Notes", isPrimary: true),
                          .init(id: "add", title: "Add Everywhere"), .init(id: "later", title: "Not Now"),
                          .init(id: "never", title: "Don\u{2019}t Suggest")]))),
            ("hidden", .hidden),
        ]
    }

    func start() {
        let step = seconds / Double(states.count + 1)
        for index in states.indices {
            Timer.scheduledTimer(withTimeInterval: step * Double(index) + 0.3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.enter(index) }
            }
        }
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                print("done: drawing panel \(self?.overlay.drawingFrame.map { "\($0)" } ?? "off screen"), control panels "
                    + "\(self?.overlay.controlFrames ?? [])")
                exit(0)
            }
        }
    }

    private func enter(_ index: Int) {
        let (name, display) = states[index]
        voiceTimer?.invalidate()
        voiceTimer = nil
        if capture > 0 { feed.captureEnded(capture: capture) }
        if case .listening = display {
            capture += 1
            let current = capture
            voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.speak(capture: current) }
            }
        }
        overlay.show(display)
        print("state: \(name)")
        if index == 0, let topology = overlay.topology { print("topology: \(topology)") }
        if let layout = overlay.layout {
            print("  body \(layout.body.frame) radii \(layout.body.topRadius)/\(layout.body.bottomRadius)")
            if let leading = layout.leading { print("  leading \(leading)") }
            if let trailing = layout.trailing { print("  trailing \(trailing)") }
            if let card = layout.card { print("  card content \(card)") }
            if let cancel = layout.cancel { print("  cancel bud \(cancel)") }
        }
        print("  drawing panel \(overlay.drawingFrame.map { "\($0)" } ?? "off screen"), control panels "
            + "\(overlay.controlFrames)")
    }

    /// 50 ms of an invented voice: a 170 Hz buzz under syllables about 0.2 s long with short gaps.
    private func speak(capture: UInt64) {
        let count = 800
        var samples = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            phase += 1
            let t = phase / 16_000
            let syllable = max(0, sin(t * 2 * .pi * 2.3)) * (0.55 + 0.45 * sin(t * 2 * .pi * 0.37))
            samples[index] = Float(0.25 * syllable * sin(t * 2 * .pi * 170))
        }
        feed.heard(samples, at: now, capture: capture)
    }
}
