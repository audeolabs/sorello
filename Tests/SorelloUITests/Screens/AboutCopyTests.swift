import Testing
@testable import SorelloUI

/// About's promise (ARCHITECTURE.md, section 9, invariant 1): what is said stays on the Mac, and the app says what it
/// connects for. It must not say the app makes no connection: it downloads its speech model, and a build with an update
/// feed checks it.
struct AboutCopyTests {
    @Test func thePromiseIsAboutWhatIsSaidAndNamesTheOneConnection() {
        #expect(AboutCopy.privacyTitle == "Nothing you say leaves this Mac.")
        #expect(AboutCopy.privacyDetail(appName: "Sorello")
                == "Speech is recognised here, and the Run Log, the dictionary and your settings stay here. Sorello connects to the network only to download its speech model.")
    }

    /// A build that can update itself makes a second connection, and says so; one that cannot says what it did.
    @Test func aBuildThatUpdatesItselfNamesBothConnections() {
        #expect(AboutCopy.privacyDetail(appName: "Sorello Nightly", checksForUpdates: true)
                == "Speech is recognised here, and the Run Log, the dictionary and your settings stay here. Sorello Nightly connects to the network only to download its speech model and to check for a newer version of itself.")
        #expect(AboutCopy.privacyDetail(appName: "Sorello", checksForUpdates: false)
                == AboutCopy.privacyDetail(appName: "Sorello"))
    }
}
