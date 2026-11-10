import DesignCore
import Testing
@testable import SorelloUI

/// Each setup step's buttons for each permission state.
struct SetupFlowTests {
    private func buttons(_ step: SetupStep, microphone: MicrophoneStatus = .granted,
                         accessibility: AccessibilityStatus = .granted) -> SetupButtons {
        SetupButtons.forStep(step, microphone: microphone, accessibility: accessibility)
    }

    @Test func theStepsRunInOrder() {
        #expect(SetupStep.allCases == [.welcome, .microphone, .accessibility, .shortcut, .test])
        #expect(SetupStep.welcome.previous == nil)
        #expect(SetupStep.test.next == nil)
        #expect(SetupStep.microphone.spokenPosition == "Step 2 of 5")
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
