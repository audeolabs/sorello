import Testing
@testable import SorelloUI

/// The state line names the most urgent thing, marks it without relying on colour alone, and offers its remedy.
struct StatusLineTests {
    @Test func everythingWellIsReady() {
        let line = AppStatus(model: .ready, microphone: .granted, accessibility: .granted).line
        #expect(line.text == "Ready")
        #expect(line.indicator == .ready)
        #expect(line.remedy == nil)
    }

    @Test func aMicrophoneNotYetAskedForIsNotAProblem() {
        let line = AppStatus(model: .ready, microphone: .notDetermined, accessibility: .granted).line
        #expect(line.indicator == .ready)
    }

    @Test func preparingShowsTheGlacierStateWithoutARemedy() {
        let line = AppStatus(model: .preparing, microphone: .granted, accessibility: .granted).line
        #expect(line.text == "Preparing model")
        #expect(line.indicator == .preparing)
        #expect(line.remedy == nil)
    }

    @Test(arguments: [ModelProblem.missing, .damaged, .couldNotLoad])
    func aFailedModelOffersRetry(problem: ModelProblem) {
        let line = AppStatus(model: .failed(problem), microphone: .granted, accessibility: .granted).line
        #expect(line.indicator == .problem)
        #expect(line.remedy == .retryModel)
    }

    @Test func aDeniedMicrophoneLeadsToItsSettings() {
        let line = AppStatus(model: .ready, microphone: .denied, accessibility: .granted).line
        #expect(line.text == "Microphone access needed")
        #expect(line.indicator == .problem)
        #expect(line.remedy == .openMicrophoneSettings)
    }

    @Test func missingAccessibilityLeadsToItsSettings() {
        let line = AppStatus(model: .ready, microphone: .granted, accessibility: .missing).line
        #expect(line.text == "Accessibility access needed")
        #expect(line.remedy == .openAccessibilitySettings)
    }

    @Test func pausedShortcutsAreNeutral() {
        let line = AppStatus(model: .ready, microphone: .granted, accessibility: .granted, shortcutsPaused: true).line
        #expect(line.indicator == .neutral)
        #expect(line.remedy == nil)
    }

    /// Every combination: a problem that needs the user always outranks one that resolves itself, and among
    /// problems the model comes first, then the microphone, then Accessibility.
    @Test func theMostUrgentStateWins() {
        let models: [ModelStatus] = [.ready, .preparing, .failed(.couldNotLoad)]
        let microphones: [MicrophoneStatus] = [.granted, .notDetermined, .denied]
        let accessibilities: [AccessibilityStatus] = [.granted, .missing]
        for model in models {
            for microphone in microphones {
                for accessibility in accessibilities {
                    for paused in [false, true] {
                        let line = AppStatus(model: model, microphone: microphone, accessibility: accessibility,
                                             shortcutsPaused: paused).line
                        let expected: StatusLine.Remedy? =
                            if case .failed = model { .retryModel }
                            else if microphone == .denied { .openMicrophoneSettings }
                            else if accessibility == .missing { .openAccessibilitySettings }
                            else { nil }
                        #expect(line.remedy == expected, "\(model) \(microphone) \(accessibility) \(paused)")
                        let indicator: StatusLine.Indicator =
                            if expected != nil { .problem }
                            else if paused { .neutral }
                            else if model == .preparing { .preparing }
                            else { .ready }
                        #expect(line.indicator == indicator, "\(model) \(microphone) \(accessibility) \(paused)")
                    }
                }
            }
        }
    }
}
