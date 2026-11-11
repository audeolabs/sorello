import DesignCore
import Testing
@testable import SorelloUI

/// Each setup step's buttons for each permission state.
struct SetupFlowTests {
    private func buttons(_ step: SetupStep, microphone: MicrophoneStatus = .granted,
                         accessibility: AccessibilityStatus = .granted, model: ModelStatus = .ready) -> SetupButtons {
        SetupButtons.forStep(step, microphone: microphone, accessibility: accessibility, model: model)
    }

    /// A setup has the model's step only when the model was not on the Mac as it opened, and moves through the
    /// steps it has.
    @Test func theStepsRunInOrder() {
        #expect(SetupStep.allCases == [.welcome, .model, .microphone, .accessibility, .shortcut, .test])
        let without = SetupStep.steps(includingModel: false)
        #expect(without == [.welcome, .microphone, .accessibility, .shortcut, .test])
        #expect(SetupStep.welcome.previous(in: without) == nil)
        #expect(SetupStep.welcome.next(in: without) == .microphone)
        #expect(SetupStep.microphone.previous(in: without) == .welcome)
        #expect(SetupStep.test.next(in: without) == nil)
        #expect(SetupStep.microphone.spokenPosition(in: without) == "Step 2 of 5")
        let with = SetupStep.steps(includingModel: true)
        #expect(with == SetupStep.allCases)
        #expect(SetupStep.welcome.next(in: with) == .model)
        #expect(SetupStep.microphone.previous(in: with) == .model)
        #expect(SetupStep.microphone.spokenPosition(in: with) == "Step 3 of 6")
    }

    /// The model's step offers the download until it starts, then Continue: it goes on behind the later steps.
    @Test func theModelStepDownloadsThenGoesOn() {
        let size: Int64 = 138_084_519
        let start = buttons(.model, model: .notDownloaded(.notStarted(size: size)))
        #expect(start.primary == SetupButton("Download", .downloadModel))
        #expect(start.secondary == SetupButton("Not Now", .advance))
        let again = buttons(.model, model: .notDownloaded(.failed(.connection, size: size)))
        #expect(again.primary == SetupButton("Try Again", .downloadModel))
        #expect(again.secondary?.action == .advance)
        for model in [ModelStatus.notDownloaded(.downloading(received: 1, size: size)), .notDownloaded(.unavailable),
                      .preparing, .ready, .failed(.couldNotLoad)] {
            #expect(buttons(.model, model: model) == SetupButtons(primary: SetupButton("Continue", .advance)), "\(model)")
        }
        #expect(SetupCopy.modelLine(appName: "Sorello", size: size)
                == "Sorello recognises speech on this Mac, with a model it downloads once from Hugging Face. It is 138 MB. Nothing you say is ever sent anywhere.")
        // With no build for this Mac there is nothing to download: the line promises neither a download nor a size.
        #expect(SetupCopy.modelLine(appName: "Sorello", size: 0)
                == "Sorello recognises speech on this Mac, with a model of its own. Nothing you say is ever sent anywhere.")
    }

    /// Until the model is ready, the test says what it is waiting for.
    @Test func theTestSaysWhatItWaitsFor() {
        let size: Int64 = 138_084_519
        #expect(SetupCopy.testWaiting(for: .notDownloaded(.downloading(received: 62_400_000, size: size)))
                == "The speech model is still downloading, 62 MB of 138 MB. Try it once it has arrived.")
        #expect(SetupCopy.testWaiting(for: .notDownloaded(.notStarted(size: size)))
                == "The speech model isn’t downloaded yet. Download it to try dictating here.")
        #expect(SetupCopy.testWaiting(for: .notDownloaded(.unavailable)) == "There is no speech model for this Mac yet.")
        for model in [ModelStatus.ready, .preparing, .failed(.couldNotLoad)] {
            #expect(SetupCopy.testWaiting(for: model) == nil)
        }
    }

    @Test func theMicrophoneStepAsksOnlyWhenItHasNotBeenAsked() {
        #expect(buttons(.microphone, microphone: .notDetermined).primary.action == .requestMicrophone)
        #expect(buttons(.microphone, microphone: .denied).primary.action == .openMicrophoneSettings)
        #expect(buttons(.microphone, microphone: .granted).primary.action == .advance)
    }

    @Test func theAccessibilityStepOpensSettingsUntilItIsGranted() {
        #expect(buttons(.accessibility, accessibility: .missing).primary.action == .openAccessibilitySettings)
        #expect(buttons(.accessibility, accessibility: .granted).primary.action == .advance)
    }

    @Test func aStepWithAMissingPermissionCanBeLeftForLater() {
        for (step, microphone, accessibility) in [(SetupStep.microphone, MicrophoneStatus.notDetermined,
                                                   AccessibilityStatus.granted),
                                                  (.microphone, .denied, .granted),
                                                  (.accessibility, .granted, .missing)] {
            #expect(buttons(step, microphone: microphone, accessibility: accessibility).secondary?.action == .advance)
        }
        #expect(buttons(.microphone).secondary == nil)
        #expect(buttons(.accessibility).secondary == nil)
    }

    @Test func onlyTheLastStepFinishes() {
        for step in SetupStep.allCases {
            let primary = buttons(step, microphone: .notDetermined, accessibility: .missing).primary.action
            #expect((primary == .finish) == (step == .test))
        }
    }
}

/// Text meets 4.5:1 on every surface it is drawn on, and the accents 3:1 (ARCHITECTURE.md, section 8).
struct ThemeContrastTests {
    @Test func whiteInkIsLegibleEverywhere() {
        for surface in ThemeColors.textSurfaces {
            #expect(RGB.contrast(Palette.ink, surface) >= 4.5, "\(surface)")
        }
    }

    @Test func secondaryInkIsLegibleEverywhere() {
        for surface in ThemeColors.textSurfaces {
            #expect(RGB.contrast(ThemeColors.secondaryInk(over: surface), surface) >= 4.5, "\(surface)")
        }
    }

    @Test func accentsStandOutEverywhere() {
        for surface in ThemeColors.textSurfaces {
            for accent in [Palette.aurora, Palette.glacier, Palette.ember, Palette.coral] {
                #expect(RGB.contrast(accent, surface) >= 3, "\(accent) on \(surface)")
            }
        }
    }
}
