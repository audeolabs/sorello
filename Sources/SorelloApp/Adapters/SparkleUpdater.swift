import AppKit
import DictationCore
import Foundation
import Observation
import Sparkle

/// The app's updater, over Sparkle (ARCHITECTURE.md, section 6, "Updates"). The only source file that imports Sparkle.
///
/// Sparkle reads the feed, the public key and its schedule from the app's `Info.plist`, which `scripts/build-app.sh`
/// writes only for a build with a feed. A check the user asks for shows Sparkle's own windows, in front. A check
/// Sparkle makes on its own shows nothing: it declares gentle reminders and declines to show any update it finds
/// (`standardUserDriverShouldHandleShowingScheduledUpdate`), so no window can arrive in front during a dictation and
/// take the paste. The menu's row reads "Update Available…" instead, until the user has seen that version or the
/// update session ends; choosing it brings Sparkle's window for it forward.
@MainActor
@Observable
final class SparkleUpdater: Updating {
    private(set) var canCheck = false
    private(set) var foundUnseen = false
    var checksAutomatically: Bool {
        get { automatic }
        set {
            automatic = newValue
            // Sparkle keeps the choice in the app's preferences, and resets its schedule a moment later.
            if started { updater.automaticallyChecksForUpdates = newValue }
        }
    }

    private var automatic = true
    @ObservationIgnored private let info: AppInfo
    @ObservationIgnored private let delegate: SparkleDelegate
    @ObservationIgnored private let updater: SPUUpdater
    @ObservationIgnored private var started = false

    /// The updater for the running app, `bundle`, which must have a feed in its `Info.plist`.
    init(info: AppInfo, bundle: Bundle = .main) {
        self.info = info
        let delegate = SparkleDelegate(feed: info.updateFeed, relaunches: true)
        self.delegate = delegate
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: delegate)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: delegate)
        delegate.foundUnasked = { [weak self] in self?.foundUnseen = true }
        delegate.seen = { [weak self] in self?.foundUnseen = false }
        delegate.canCheckChanged = { [weak self] in
            guard let self else { return }
            canCheck = updater.canCheckForUpdates
        }
    }

    func start() {
        guard !started else { return }
        SparkleDelegate.configure(updater, info: info)
        do {
            try updater.start()
        } catch {
            // Only a build made wrongly gets here: the feed and the key are written together. It then has no updater
            // to offer, and says nothing.
            Diagnostics.record("updates.notStarted")
            return
        }
        started = true
        automatic = updater.automaticallyChecksForUpdates
        canCheck = updater.canCheckForUpdates
        delegate.observe(updater)
    }

    func checkForUpdates() {
        guard started else { return }
        updater.checkForUpdates()
    }
}

/// What Sparkle asks of the app, for the app's updater and for the self-test's. It never lets Sparkle show an update
/// it found on its own, never lets it ask whether it may check, allows no system profile, and gives Sparkle no cookie
/// to send: the cookies of the app's own store are cleared before each check and after the feed has loaded, and the
/// download of an update neither sends nor keeps one.
@MainActor
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    /// The only feed Sparkle may read; one left in the preferences is never followed.
    let feed: URL?
    let relaunches: Bool
    var foundUnasked: () -> Void = {}
    var seen: () -> Void = {}
    var canCheckChanged: () -> Void = {}
    private weak var observed: SPUUpdater?

    init(feed: URL?, relaunches: Bool) {
        self.feed = feed
        self.relaunches = relaunches
    }

    isolated deinit {
        observed?.removeObserver(self, forKeyPath: Self.canCheckKey)
    }

    /// What every request Sparkle makes says about the app: its name and version, and nothing about the user's
    /// languages.
    static func configure(_ updater: SPUUpdater, info: AppInfo) {
        updater.userAgentString = "\(info.name)/\(info.version)"
        updater.httpHeaders = ["Accept-Language": "en"]
        clearCookies()
    }

    static func clearCookies() {
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
    }

    // MARK: Whether the user can ask for a check

    nonisolated private static let canCheckKey = "canCheckForUpdates"

    func observe(_ updater: SPUUpdater) {
        guard observed == nil else { return }
        observed = updater
        updater.addObserver(self, forKeyPath: Self.canCheckKey, options: [.new], context: nil)
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.canCheckKey else { return }
        // Sparkle changes it on the main thread, which it requires of everything it does.
        MainActor.assumeIsolated { canCheckChanged() }
    }

    // MARK: SPUUpdaterDelegate

    @objc(feedURLStringForUpdater:)
    func feedURLString(for updater: SPUUpdater) -> String? { feed?.absoluteString }

    @objc(updaterShouldPromptForPermissionToCheckForUpdates:)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    @objc(allowedSystemProfileKeysForUpdater:)
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    @objc(updater:mayPerformUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        Self.clearCookies()
    }

    @objc(updater:didFinishLoadingAppcast:)
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Self.clearCookies()
    }

    @objc(updater:willDownloadUpdate:withRequest:)
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        request.httpShouldHandleCookies = false
    }

    @objc(updaterShouldRelaunchApplication:)
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { relaunches }
}

/// Gentle reminders (Sparkle's documentation, "Gentle Update Reminders"): Sparkle's standard windows for a check the
/// user asked for, and none for one Sparkle made on its own.
extension SparkleDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    @objc var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never, even near launch, when Sparkle would otherwise bring the app forward with it.
    @objc(standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:)
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    @objc(standardUserDriverWillHandleShowingUpdate:forUpdate:state:)
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { foundUnasked() }
    }

    @objc(standardUserDriverDidReceiveUserAttentionForUpdate:)
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        seen()
    }

    @objc(standardUserDriverWillFinishUpdateSession)
    func standardUserDriverWillFinishUpdateSession() {
        seen()
    }
}

// MARK: - The self-test

/// `Sorello --self-test --update <feed>` (ARCHITECTURE.md, section 11): the packaged app's own updater, with the key in
/// its `Info.plist`, against the feed given, for this run only. It shows no window: a user driver of its own answers
/// for the user. It installs a newer build it finds, once Sparkle has downloaded it and verified its signature, and
/// the installer replaces this app with it as the command ends, without opening it.
enum SparkleUpdateTest {
    /// How long the whole test may take: the feed, the download and the installer's preparation.
    static let limit: Duration = .seconds(300)

    /// Runs the test, reporting each fact as one line, and returns whether it passed. "None newer" passes: the feed
    /// was read and verified to offer nothing to install.
    static func run(feed: URL, info: AppInfo, report: @escaping (String) -> Void) async -> Bool {
        let delegate = SparkleDelegate(feed: feed, relaunches: false)
        let driver = HeadlessDriver(info: info, report: report)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
        SparkleDelegate.configure(updater, info: info)
        do {
            try updater.start()
        } catch {
            report("update: failed: the updater did not start: \(HeadlessDriver.reason(error))")
            return false
        }
        // Before Sparkle's own cycle begins, on the next turn of the run loop.
        updater.checkForUpdates()
        let passed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            driver.finish = { continuation.resume(returning: $0) }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                driver.fail("no answer within \(limit.components.seconds) s")
            }
        }
        withExtendedLifetime((delegate, updater)) {}
        return passed
    }
}

/// Sparkle's user driver for the self-test: it says what Sparkle reports, chooses Install for a newer build, and lets
/// the installer go on once this process has ended.
@MainActor
private final class HeadlessDriver: NSObject, SPUUserDriver {
    private let info: AppInfo
    private let report: (String) -> Void
    private var received: UInt64 = 0
    private var finished = false
    var finish: (Bool) -> Void = { _ in }

    init(info: AppInfo, report: @escaping (String) -> Void) {
        self.info = info
        self.report = report
    }

    func fail(_ reason: String) {
        guard !finished else { return }
        report("update: failed: \(reason)")
        end(false)
    }

    private func end(_ passed: Bool) {
        guard !finished else { return }
        finished = true
        finish(passed)
    }

    /// An error's description and, when it has one, its underlying error's, which usually says why.
    static func reason(_ error: any Error) -> String {
        let error = error as NSError
        var words = error.localizedDescription
        if let failure = error.localizedFailureReason, !words.contains(failure) { words += " " + failure }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            words += " (\(underlying.localizedDescription))"
        }
        return words
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The app never asks; were Sparkle to, the answer would change nothing it keeps.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        report("update: found \(appcastItem.displayVersionString) (\(appcastItem.versionString))")
        if appcastItem.isInformationOnlyUpdate {
            reply(.dismiss)
            fail("the feed offers that version for information only, with nothing to install")
            return
        }
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        guard !finished else { return }
        report("update: none newer than \(info.version) (\(info.build))")
        end(true)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        fail(Self.reason(error))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        received = 0
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
    }

    func showDownloadDidStartExtractingUpdate() {
        report("update: downloaded \(received) bytes")
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    /// Sparkle has verified the update against the app's key and the installer is ready. Dismissing leaves it waiting
    /// for this process to end, and then it installs without opening the app.
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.dismiss)
        guard !finished else { return }
        report("update: verified; installs as this command ends")
        end(true)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        guard !finished else { return }
        report("update: verified; installing")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        guard !finished else { return }
        report("update: installed")
        end(true)
    }

    func dismissUpdateInstallation() {}
}
