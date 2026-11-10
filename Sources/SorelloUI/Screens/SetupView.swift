import SwiftUI

/// What setup asks of the app layer.
public struct SetupActions {
    /// Ask for the microphone; the system shows its prompt.
    public var requestMicrophone: () -> Void
    /// Open the microphone pane of System Settings, after access was denied.
    public var openMicrophoneSettings: () -> Void
    /// Open System Settings with the card to drag into the Accessibility list.
    public var openAccessibilitySettings: () -> Void
    /// Open the Keyboard pane of System Settings, for the fn key's own action.
    public var openKeyboardSettings: () -> Void
    /// Load the speech model again after a failure.
    public var retryModel: () -> Void
    /// Record Hold to Talk's shortcut.
    public var recorder: ShortcutRecorderActions
    /// Setup is done; the window closes.
    public var finish: () -> Void

    /// Actions that each do nothing unless given.
    public init(requestMicrophone: @escaping () -> Void = {}, openMicrophoneSettings: @escaping () -> Void = {},
                openAccessibilitySettings: @escaping () -> Void = {}, openKeyboardSettings: @escaping () -> Void = {},
                retryModel: @escaping () -> Void = {}, recorder: ShortcutRecorderActions = ShortcutRecorderActions(),
                finish: @escaping () -> Void = {}) {
        self.requestMicrophone = requestMicrophone
        self.openMicrophoneSettings = openMicrophoneSettings
        self.openAccessibilitySettings = openAccessibilitySettings
        self.openKeyboardSettings = openKeyboardSettings
        self.retryModel = retryModel
        self.recorder = recorder
        self.finish = finish
    }
}

/// Setup's values.
@Observable
public final class SetupModel {
    /// The app's name as installed.
    public var appName: String
    /// The step showing. The view moves it; the app layer may set it.
    public var step: SetupStep
    /// Microphone access, kept current by the app layer.
    public var microphone: MicrophoneStatus
    /// Accessibility access, kept current by the app layer.
    public var accessibility: AccessibilityStatus
    /// The speech model, for the live test.
    public var model: ModelStatus
    /// Hold to Talk's recorder.
    public var holdToTalk: ShortcutRecorderState
    /// What the live test's field holds: what the user dictated into it, or typed.
    public var testText: String
    /// What setup asks of the app layer.
    public var actions: SetupActions

    /// Setup's values, starting at `step`.
    public init(appName: String, step: SetupStep = .welcome, microphone: MicrophoneStatus,
                accessibility: AccessibilityStatus, model: ModelStatus, holdToTalk: ShortcutRecorderState,
                testText: String = "", actions: SetupActions = SetupActions()) {
        self.appName = appName
        self.step = step
        self.microphone = microphone
        self.accessibility = accessibility
        self.model = model
        self.holdToTalk = holdToTalk
        self.testText = testText
        self.actions = actions
    }
}

/// Setup: welcome, the microphone, Accessibility, the shortcut, and a live test into a field of its own. Each step
/// says in one sentence why it is needed, and every step can be left for later.
public struct SetupView: View {
    @Bindable private var model: SetupModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Setup drawn from `model`.
    public init(model: SetupModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 18)
            ZStack {
                step
                    .id(model.step)
                    .transition(reduceMotion ? .opacity
                                : .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)),
                                              removal: .opacity.combined(with: .offset(x: -24))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            buttons
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
        }
        .background(Theme.screen)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(Theme.ink)
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.allCases, id: \.self) { item in
                Capsule()
                    .fill(Color.white.opacity(item == model.step ? 1 : item.rawValue < model.step.rawValue ? 0.5 : 0.2))
                    .frame(width: item == model.step ? 22 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.88), value: model.step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Setup"))
        .accessibilityValue(model.step.spokenPosition)
    }

    private var buttons: some View {
        let buttons = SetupButtons.forStep(model.step, microphone: model.microphone, accessibility: model.accessibility)
        return HStack(spacing: 10) {
            if let previous = model.step.previous {
                Button { go(to: previous) } label: { Label(String(localized: "Back"), systemImage: "chevron.left") }
                    .buttonStyle(QuietButtonStyle())
            }
            Spacer()
            if let secondary = buttons.secondary {
                Button(secondary.title) { perform(secondary.action) }
                    .buttonStyle(QuietButtonStyle())
            }
            primary(buttons.primary)
        }
    }

    /// The main button answers Return, except on the live test: a dictation ending in "press enter" posts Return
    /// into the test field, and that must not close setup.
    @ViewBuilder
    private func primary(_ button: SetupButton) -> some View {
        let view = Button(button.title) { perform(button.action) }
            .buttonStyle(PrimaryButtonStyle(size: .large))
        if model.step == .test {
            view
        } else {
            view.keyboardShortcut(.defaultAction)
        }
    }

    private func perform(_ action: SetupAction) {
        switch action {
        case .advance: if let next = model.step.next { go(to: next) }
        case .requestMicrophone: model.actions.requestMicrophone()
        case .openMicrophoneSettings: model.actions.openMicrophoneSettings()
        case .openAccessibilitySettings: model.actions.openAccessibilitySettings()
        case .finish: model.actions.finish()
        }
    }

    private func go(to step: SetupStep) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.9)) {
            model.step = step
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome: WelcomeStep(appName: model.appName)
        case .microphone: MicrophoneStep(model: model)
        case .accessibility: AccessibilityStep(model: model)
        case .shortcut: ShortcutStep(model: model)
        case .test: TestStep(model: model)
        }
    }
}

/// A step's glyph, headline and one sentence, centred, then its content.
private struct StepLayout<Content: View>: View {
    let symbol: String?
    let title: String
    let line: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.ink)
                    .frame(height: 44)
                    .padding(.bottom, 18)
                    .accessibilityHidden(true)
            }
            Text(title)
                .displayType(.stepTitle)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            content
                .padding(.top, 28)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 32)
    }
}

private struct WelcomeStep: View {
    let appName: String

    var body: some View {
        VStack(spacing: 0) {
            MarkEmblem(scale: 1.4)
                .padding(.bottom, 30)
            Text(verbatim: appName)
                .displayType(DisplayType(size: 52))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Hold a key and speak. Let go, and your words appear wherever you were typing.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            HStack(alignment: .top, spacing: 8) {
                Promise(symbol: "laptopcomputer", text: String(localized: "On this Mac"))
                Promise(symbol: "network.slash", text: String(localized: "No network"))
                Promise(symbol: "lock", text: String(localized: "Kept only here"))
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .cardSurface(radius: 16)
            .padding(.top, 30)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 32)
    }
}

private struct Promise: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Theme.ink)
                .frame(height: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MicrophoneStep: View {
    let model: SetupModel

    var body: some View {
        StepLayout(symbol: "mic", title: String(localized: "Allow the microphone"),
                   line: String(localized: "It listens only while you hold the shortcut, and the sound never leaves this Mac.")) {
            Card {
                MicrophonePermissionRow(status: model.microphone, actions: GeneralActions(), offersFix: false)
            }
        }
    }
}

private struct AccessibilityStep: View {
    let model: SetupModel

    var body: some View {
        StepLayout(symbol: "accessibility", title: String(localized: "Allow Accessibility"),
                   line: String(localized: "It lets the shortcut work in every app and puts your words at the cursor.")) {
            VStack(spacing: 12) {
                if model.accessibility == .missing {
                    VStack(alignment: .leading, spacing: 12) {
                        NumberedStep(number: 1, text: String(localized: "Click Open System Settings."))
                        NumberedStep(number: 2, text: String(localized: "Drag \(model.appName) from the card into the list."))
                        NumberedStep(number: 3, text: String(localized: "Turn it on, then come back here."))
                    }
                    .padding(Metrics.rowInset + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSurface()
                }
                Card {
                    AccessibilityPermissionRow(status: model.accessibility, actions: GeneralActions(), offersFix: false)
                }
            }
        }
    }
}

/// A numbered instruction: the number on a small island disc, then the words.
private struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ink)
                .frame(width: 22, height: 22)
                .islandSurface(Circle())
                .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] }
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Step \(number): \(text)"))
    }
}

private struct ShortcutStep: View {
    let model: SetupModel

    var body: some View {
        StepLayout(symbol: "keyboard", title: String(localized: "Choose your shortcut"),
                   line: String(localized: "Hold it to talk and let go to paste. Tap it twice to talk hands-free, and once more to finish. fn works on every Mac keyboard.")) {
            VStack(spacing: 12) {
                Card { ShortcutRecorderRow(.holdToTalk, state: model.holdToTalk, actions: model.actions.recorder) }
                if model.holdToTalk.keys?.modifiers.contains(.function) == true {
                    FunctionKeyNote(openKeyboardSettings: model.actions.openKeyboardSettings)
                }
            }
        }
    }
}

/// The live test: a field of its own takes the keyboard focus, so a dictation lands here by the ordinary paste and
/// nowhere else. The pill appears at the top of the screen as it always does.
private struct TestStep: View {
    @Bindable var model: SetupModel
    @FocusState private var focused: Bool

    var body: some View {
        StepLayout(symbol: "character.cursor.ibeam", title: String(localized: "Try it"),
                   line: SetupCopy.testInstruction(hold: model.holdToTalk.keys ?? .function)) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(text: $model.testText,
                          prompt: Text("Your words appear here").foregroundStyle(Theme.secondaryInk), axis: .vertical) {
                    Text("Test field")
                }
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
                .lineLimit(4...6)
                .focused($focused)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(focused ? Color.white.opacity(0.6) : Theme.edge, lineWidth: focused ? 1 : 0.5))
                .accessibilityLabel(String(localized: "Test field"))
                .accessibilityHint(SetupCopy.testInstruction(hold: model.holdToTalk.keys ?? .function))
                outcome
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.model {
        case .failed(let problem):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                InlineMessage(problem.explanation)
                Spacer(minLength: 8)
                Button(String(localized: "Retry"), action: model.actions.retryModel)
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
            }
        case .preparing:
            HStack(spacing: 8) {
                StatusIndicator(.preparing, size: 7)
                Text("The speech model is still preparing. Your words appear as soon as it is ready.")
                    .font(.rowDetail)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        case .ready:
            if !model.testText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.aurora)
                        .accessibilityHidden(true)
                    Text("It works. You’re ready.")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
