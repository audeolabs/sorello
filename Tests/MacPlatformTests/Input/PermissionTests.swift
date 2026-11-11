@preconcurrency import AVFoundation
import CoreGraphics
import DictationCore
import Foundation
@testable import MacPlatform
import Synchronization
import Testing

@Suite("Privacy permission words and links")
struct PrivacyPermissionTests {
    @Test("Accessibility's pane is renamed on macOS 27")
    func titles() {
        #expect(PrivacyPermission.accessibility.settingsTitle(macOSMajorVersion: 26) == "Accessibility")
        #expect(PrivacyPermission.accessibility.settingsTitle(macOSMajorVersion: 27) == "Device Control and Data Access")
        #expect(PrivacyPermission.microphone.settingsTitle(macOSMajorVersion: 27) == "Microphone")
    }

    @Test("Instructions name the pane for the version")
    func instructions() {
        #expect(PrivacyPermission.accessibility.enableInstructions(appName: "Synthetic Dictation", macOSMajorVersion: 27)
                == "Go to System Settings > Privacy & Security > Device Control and Data Access and enable Synthetic Dictation.")
        #expect(PrivacyPermission.accessibility.enableInstructions(appName: "Synthetic Dictation", macOSMajorVersion: 26)
                == "Go to System Settings > Privacy & Security > Accessibility and enable Synthetic Dictation.")
    }

    @Test("Each permission opens its own pane")
    func urls() {
        for (permission, anchor) in [(PrivacyPermission.microphone, "Privacy_Microphone"),
                                     (.accessibility, "Privacy_Accessibility")] {
            #expect(permission.settingsURL.scheme == "x-apple.systempreferences")
            // Foundation versions differ in whether an opaque custom-scheme URL exposes a query; Settings
            // receives the whole serialized URL.
            #expect(permission.settingsURL.absoluteString
                    == "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        }
    }

    @Test("Only Accessibility's list takes a dragged app")
    func draggable() {
        #expect(PrivacyPermission.accessibility.acceptsDraggedApp)
        #expect(!PrivacyPermission.microphone.acceptsDraggedApp)
    }

    @Test("Alerts explain what is missing and how to grant it")
    func alerts() {
        #expect(PrivacyPermission.microphone.alertText(appName: "Synthetic Dictation", macOSMajorVersion: 27)
                == PermissionAlertText(
                    title: "Microphone Permission Required",
                    message: "Synthetic Dictation cannot record audio without Microphone access.\n\nGo to System Settings > Privacy & Security > Microphone and enable Synthetic Dictation.",
                    symbolName: "mic.fill"))
        for (version, pane) in [(26, "Accessibility"), (27, "Device Control and Data Access")] {
            #expect(PrivacyPermission.accessibility.alertText(appName: "Synthetic Dictation", macOSMajorVersion: version)
                    == PermissionAlertText(
                        title: "\(pane) Permission Required",
                        message: "Synthetic Dictation needs this access for global shortcuts and pasting transcribed text.\n\nGo to System Settings > Privacy & Security > \(pane) and enable Synthetic Dictation.\n\nIf the app is already enabled but access is still missing, remove its entry with −, add this copy with +, and enable it again.",
                        symbolName: "exclamationmark.triangle.fill"))
        }
    }
}

@Suite("Microphone permission")
struct MicrophonePermissionTests {
    private final class Asked: Sendable {
        let count = Mutex(0)
    }

    @Test("The system's status maps to the session's access", arguments: [
        (AVAuthorizationStatus.authorized, MicrophoneAccess.granted), (.notDetermined, .unknown), (.denied, .denied),
        (.restricted, .denied),
    ])
    func mapping(status: AVAuthorizationStatus, access: MicrophoneAccess) {
        #expect(MicrophonePermission(status: { status }, ask: { true }).current() == access)
    }

    @Test("request asks only while access is undecided")
    func requestOnlyWhenUnknown() async {
        let asked = Asked()
        for (status, answer, expected) in [(AVAuthorizationStatus.notDetermined, true, MicrophoneAccess.granted),
                                           (.notDetermined, false, .denied), (.denied, true, .denied),
                                           (.authorized, false, .granted)] {
            let permission = MicrophonePermission(status: { status }, ask: {
                asked.count.withLock { $0 += 1 }
                return answer
            })
            #expect(await permission.request() == expected)
        }
        #expect(asked.count.withLock { $0 } == 2)
    }

    @Test("Reading the real status never prompts")
    func realStatus() {
        _ = MicrophonePermission().current()
    }
}

@Suite("Accessibility permission")
struct AccessibilityPermissionTests {
    private final class Trust: Sendable {
        let value = Mutex(false)
        let reads = Mutex(0)
        func read() -> Bool {
            reads.withLock { $0 += 1 }
            return value.withLock { $0 }
        }
    }

    @Test("changes reports the trust now, then only changes, polled while someone listens")
    func changes() async {
        let clock = TestClock()
        let trust = Trust()
        let permission = AccessibilityPermission(clock: clock, isTrusted: { trust.read() })
        #expect(permission.isTrusted == false)
        var iterator: AsyncStream<Bool>.Iterator? = permission.changes().makeAsyncIterator()
        #expect(await iterator?.next() == false)
        await clock.waitForSleepers()
        clock.advance(by: AccessibilityPermission.pollInterval)
        await clock.waitForSleepers()
        trust.value.withLock { $0 = true }
        clock.advance(by: AccessibilityPermission.pollInterval)
        #expect(await iterator?.next() == true)
        iterator = nil
        for _ in 0..<1_000 where clock.sleeperCount > 0 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(clock.sleeperCount == 0, "polling stops when nobody listens")
    }

    @Test("Reading the real trust never prompts")
    func realTrust() {
        _ = AccessibilityPermission().isTrusted
    }
}

@Suite("Drag card geometry")
struct PermissionPanelTests {
    @Test("The app row matches the Privacy list's column, within 320 to 640 pt")
    func layout() {
        #expect(PermissionPanel.Layout(settingsWidth: 740).rowWidth == 468)
        #expect(PermissionPanel.Layout(settingsWidth: 500).rowWidth == 320)
        #expect(PermissionPanel.Layout(settingsWidth: 1200).rowWidth == 640)
        #expect(PermissionPanel.Layout(settingsWidth: 740).cardSize == CGSize(width: 532, height: 95))
    }

    /// AppKit coordinates (origin bottom-left) on a 2560 x 1440 screen with a 30 pt menu bar.
    @Test("The card docks below, inside, beside or clamped, in that order")
    func dockPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1410)
        let cases: [(String, CGRect, CGRect, PermissionPanel.Dock)] = [
            ("room below", CGRect(x: 1640, y: 320, width: 740, height: 820), screen, .below),
            ("no room below", CGRect(x: 1640, y: 100, width: 740, height: 820), screen, .inside),
            ("short window, no room", CGRect(x: 1000, y: 60, width: 740, height: 300), screen, .right),
            ("short, at the right edge", CGRect(x: 1820, y: 60, width: 740, height: 300), screen, .left),
            ("lower 30% off the screen", CGRect(x: 1640, y: -200, width: 740, height: 820), screen, .left),
            ("small screen", CGRect(x: 0, y: 0, width: 740, height: 600), CGRect(x: 0, y: 0, width: 740, height: 600),
             .inside),
            ("window fills a tiny screen", CGRect(x: 0, y: 0, width: 740, height: 300),
             CGRect(x: 0, y: 0, width: 740, height: 300), .clamped),
        ]
        for (name, settings, visible, expected) in cases {
            let layout = PermissionPanel.Layout(settingsWidth: settings.width)
            let plan = PermissionPanel.dock(settings: settings, visible: visible, layout: layout)
            #expect(plan.dock == expected, "\(name)")
            #expect(plan.frame.size == layout.cardSize)
        }
        let layout = PermissionPanel.Layout(settingsWidth: 740)
        let below = PermissionPanel.dock(settings: CGRect(x: 1640, y: 320, width: 740, height: 820), visible: screen,
                                         layout: layout)
        #expect(below.frame == CGRect(x: 1840, y: 215, width: 532, height: 95), "10 pt under, on the list's column")
        let inside = PermissionPanel.dock(settings: CGRect(x: 1640, y: 100, width: 740, height: 820), visible: screen,
                                          layout: layout)
        #expect(inside.frame == CGRect(x: 1840, y: 120, width: 532, height: 95), "20 pt above the bottom edge")
    }

    @Test("Window-server and AppKit coordinates convert both ways")
    func coordinates() {
        let quartz = CGRect(x: 10, y: 20, width: 100, height: 50)
        let appKit = PermissionPanel.appKit(fromQuartz: quartz, primaryHeight: 1000)
        #expect(appKit == CGRect(x: 10, y: 930, width: 100, height: 50))
        #expect(PermissionPanel.quartz(fromAppKit: appKit, primaryHeight: 1000) == quartz)
    }

    @Test("The flight's spring settles without overshoot; a bouncy one overshoots")
    func spring() {
        let spring = PermissionPanel.Spring(duration: 0.85, bounce: 0)
        #expect(spring.value(0) == 0)
        #expect(spring.value(-1) == 0)
        #expect(abs(spring.value(spring.settleTime) - 1) < 0.001)
        var previous = 0.0
        for step in 1...100 {
            let value = spring.value(spring.settleTime * Double(step) / 100)
            #expect(value >= previous && value <= 1)
            previous = value
        }
        let bouncy = PermissionPanel.Spring(duration: 0.5, bounce: 0.3)
        #expect((1...100).contains { bouncy.value(bouncy.settleTime * Double($0) / 100) > 1 })
    }

    @Test("The flight arcs above the higher end, less on short hops, never past the ceiling")
    func flightArc() {
        let source = CGRect(x: 100, y: 500, width: 120, height: 30)
        let farTarget = CGRect(x: 1500, y: 200, width: 532, height: 95)
        let far = PermissionPanel.flightControl(source: source, target: farTarget, ceiling: 10_000)
        #expect(far.x == (source.midX + farTarget.midX) / 2)
        #expect(far.y == source.midY + 160)
        let nearTarget = CGRect(x: 160, y: 500, width: 120, height: 30)
        let near = PermissionPanel.flightControl(source: source, target: nearTarget, ceiling: 10_000)
        #expect(abs(Double(near.y) - Double(source.midY + 60 * 0.35)) < 0.0001)
        #expect(PermissionPanel.flightControl(source: source, target: farTarget, ceiling: 550).y == 550)
        #expect(PermissionPanel.flightControl(source: source, target: farTarget, ceiling: 0).y == source.midY)
    }

    @Test("After a drop the card waits for Settings' authentication sheet to close, or 10 s")
    func dropRace() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        func run(from count: Int, _ steps: [(windows: Int, after: TimeInterval)]) -> [Bool] {
            var race = PermissionPanel.DropRace(droppedAt: start, settingsWindowCount: count)
            return steps.map { race.observe(settingsWindowCount: $0.windows, at: start.addingTimeInterval($0.after)) }
        }
        // Nothing yet, a sheet opens, it is still open, it is dismissed.
        #expect(run(from: 1, [(1, 1), (2, 2), (2, 5), (1, 6)]) == [false, false, false, true])
        // No sheet: the race ends at the deadline.
        #expect(run(from: 1, [(1, 9.9), (1, 10.1)]) == [false, true])
        // A Settings window closing also ends it.
        #expect(run(from: 2, [(1, 1)]) == [true])
    }
}
