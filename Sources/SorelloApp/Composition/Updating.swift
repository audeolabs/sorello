import Foundation
import SorelloUI

/// The app's updater, as the rest of the app sees it (ARCHITECTURE.md, section 6, "Updates"). `SparkleUpdater` is the
/// one implementation, and the one file that imports Sparkle; tests use a fake, so no test starts Sparkle. Only a build
/// with an update feed has one. An implementation is observable, so the menu and General follow it.
@MainActor
protocol Updating: AnyObject {
    /// Whether the user can ask for a check now. False while the updater is busy with a check of its own.
    var canCheck: Bool { get }
    /// A check made on its own found a newer version that the user has not yet seen, installed or skipped. The menu
    /// then reads "Update Available…", and no window has come forward by itself.
    var foundUnseen: Bool { get }
    /// Whether the updater checks once a day by itself: General's switch, on from the first launch. Off, only the
    /// menu's command checks.
    var checksAutomatically: Bool { get set }
    /// Starts the updater, which schedules its daily check. Called once, as the app starts.
    func start()
    /// The menu's row was chosen: shows the updater's own window, in front, for a new check or for the version a
    /// check made on its own found.
    func checkForUpdates()
}

/// What the app does about updates that is not the updater's: whether a build gets one, and what the menu shows of it.
enum Updates {
    /// The key a feed address set in the preferences would be kept under. The app follows only the feed in its
    /// `Info.plist`, so one left there is removed at launch.
    static let storedFeedKey = "SUFeedURL"

    /// The build's updater, made by `make`, or nil when the build has no update feed: then Sparkle is never started,
    /// and the menu and General show nothing of updates.
    static func updater(for info: AppInfo, make: (AppInfo) -> any Updating) -> (any Updating)? {
        info.updateFeed == nil ? nil : make(info)
    }

    /// The menu's update row for `updater`, or none without one.
    static func row(_ updater: (any Updating)?) -> UpdateRowState? {
        guard let updater else { return nil }
        return updater.foundUnseen ? .updateAvailable : .checkForUpdates(isEnabled: updater.canCheck)
    }
}
