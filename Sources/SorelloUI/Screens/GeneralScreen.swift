import SwiftUI

/// What the General screen does when its controls are used.
public struct GeneralActions {
    /// Load the speech model again after a failure.
    public var retryModel: () -> Void
    /// Start the speech model's download, or go on with it after it stopped.
    public var downloadModel: () -> Void
    /// Stop the download; what arrived is kept.
    public var cancelDownload: () -> Void
    /// Ask for the microphone; the system shows its prompt.
    public var requestMicrophone: () -> Void
    /// Open the microphone pane of System Settings, after access was denied.
    public var openMicrophoneSettings: () -> Void
    /// Lead the user to grant Accessibility: System Settings, with the card to drag in.
    public var openAccessibilitySettings: () -> Void
    /// Nil chooses the system default.
    public var selectMicrophone: (String?) -> Void
    /// A switch was flipped; the model already shows the new value.
    public var setToggle: (GeneralToggle, Bool) -> Void

    /// Actions that each do nothing unless given.
    public init(retryModel: @escaping () -> Void = {}, downloadModel: @escaping () -> Void = {},
                cancelDownload: @escaping () -> Void = {}, requestMicrophone: @escaping () -> Void = {},
                openMicrophoneSettings: @escaping () -> Void = {}, openAccessibilitySettings: @escaping () -> Void = {},
                selectMicrophone: @escaping (String?) -> Void = { _ in },
                setToggle: @escaping (GeneralToggle, Bool) -> Void = { _, _ in }) {
        self.retryModel = retryModel
        self.downloadModel = downloadModel
        self.cancelDownload = cancelDownload
        self.requestMicrophone = requestMicrophone
        self.openMicrophoneSettings = openMicrophoneSettings
        self.openAccessibilitySettings = openAccessibilitySettings
        self.selectMicrophone = selectMicrophone
        self.setToggle = setToggle
    }
}

/// Where speech is recognised on this Mac, as the General screen says it. The app layer reads it from the engine,
/// which reads it from the hardware.
nonisolated public enum ModelHardware: Sendable, Equatable {
    /// The Neural Engine, which every Apple silicon Mac has.
    case neuralEngine
    /// The Mac's processor, on a Mac without a Neural Engine, which is every Intel Mac.
    case processor
}

/// The General screen's values.
@Observable
public final class GeneralModel {
    /// The speech model's name, as the pin gives it.
    public var modelName: String
    /// The model and permissions, as every window shows them.
    public var status: AppStatus
    /// Where the model runs on this Mac.
    public var hardware: ModelHardware
    /// The microphones connected now.
    public var microphones: [MicrophoneOption]
    /// The chosen microphone's identifier; nil follows the system default.
    public var selectedMicrophoneID: String?
    /// The system default's name, shown beside "System default".
    public var defaultMicrophoneName: String?
    /// Each switch's value.
    public var toggles: [GeneralToggle: Bool]
    /// Whether the app can update itself, and so shows the switch for its daily check. A build with no update feed
    /// cannot, and has no such switch.
    public var offersUpdates: Bool
    /// What the screen asks of the app layer.
    public var actions: GeneralActions

    /// The General screen's values. `hardware` is the Neural Engine until the app layer says otherwise.
    public init(modelName: String, status: AppStatus, hardware: ModelHardware = .neuralEngine,
                microphones: [MicrophoneOption], selectedMicrophoneID: String?,
                defaultMicrophoneName: String?, toggles: [GeneralToggle: Bool], offersUpdates: Bool = false,
                actions: GeneralActions = GeneralActions()) {
        self.modelName = modelName
        self.status = status
        self.hardware = hardware
        self.microphones = microphones
        self.selectedMicrophoneID = selectedMicrophoneID
        self.defaultMicrophoneName = defaultMicrophoneName
        self.toggles = toggles
        self.offersUpdates = offersUpdates
        self.actions = actions
    }

    /// A switch's value. A switch the app layer has not set reads as off.
    public func isOn(_ toggle: GeneralToggle) -> Bool { toggles[toggle] ?? false }
}

/// General: the model's state, the permissions, the microphone, and the switches that shape the text.
public struct GeneralScreen: View {
    @Bindable private var model: GeneralModel

    /// The General screen drawn from `model`.
    public init(model: GeneralModel) {
        self.model = model
    }

    public var body: some View {
        ScreenPage(String(localized: "General")) {
            CardGroup(String(localized: "Speech model")) {
                Card {
                    ModelRow(name: model.modelName, status: model.status.model, hardware: model.hardware,
                             actions: model.actions)
                }
            }
            CardGroup(String(localized: "Permissions")) {
                Card(dividerInset: Metrics.wordsInset) {
                    MicrophonePermissionRow(status: model.status.microphone, actions: model.actions)
                    AccessibilityPermissionRow(status: model.status.accessibility, actions: model.actions)
                }
            }
            CardGroup(String(localized: "Input")) {
                Card {
                    SettingRow(String(localized: "Microphone"), symbol: "mic") {
                        MicrophonePicker(model: model)
                    }
                }
            }
            CardGroup(String(localized: "Text")) {
                Card(dividerInset: Metrics.wordsInset) {
                    toggleRow(.spokenNumbers)
                    toggleRow(.spokenDelimiters)
                    toggleRow(.pressEnter)
                    toggleRow(.correctionSuggestions)
                }
            } footer: {
                if model.status.accessibility == .missing && model.isOn(.correctionSuggestions) {
                    Text("Suggestions need Accessibility, to see the word you fix.")
                }
            }
            CardGroup(String(localized: "App")) {
                Card(dividerInset: Metrics.wordsInset) {
                    toggleRow(.launchAtLogin)
                    toggleRow(.restoreClipboard)
                    toggleRow(.keepRunLog)
                    if model.offersUpdates { toggleRow(.checkForUpdates) }
                }
            }
        }
    }

    private func toggleRow(_ toggle: GeneralToggle) -> some View {
        ToggleRow(toggle.title, symbol: toggle.symbol, isOn: Binding(
            get: { model.isOn(toggle) },
            set: { value in
                model.toggles[toggle] = value
                model.actions.setToggle(toggle, value)
            }))
    }
}

/// The model's state: ready, preparing with a travelling glacier line, or failed with the reason and Retry; and when
/// the model is not on this Mac, its download: its size and Download, how much has arrived as a bar and in words with
/// Cancel, why it stopped with Try Again, or that there is none for this Mac. Ready and preparing say where the model
/// runs, because that decides how long preparing takes.
struct ModelRow: View {
    let name: String
    let status: ModelStatus
    let hardware: ModelHardware
    let actions: GeneralActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Metrics.glyphGap) {
                RowGlyph("cpu")
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.ink)
                    Text(Self.detail(status, on: hardware))
                        .font(.rowDetail)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(localized: "Speech model"))
                .accessibilityValue(spokenState)
                Spacer(minLength: 12)
                trailing
            }
        }
        .rowPadding()
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .ready:
            HStack(spacing: 6) {
                StatusIndicator(.ready)
                Text("Ready").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
            }
            .accessibilityHidden(true)
        case .preparing:
            HStack(spacing: 8) {
                GlacierBar().frame(width: 72)
                Text("Preparing").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
            }
            .accessibilityHidden(true)
        case .failed:
            HStack(spacing: 10) {
                StatusIndicator(.problem)
                Button(String(localized: "Retry"), action: actions.retryModel)
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
                    .accessibilityHint(StatusLine.Remedy.retryModel.hint)
            }
        case .notDownloaded(.notStarted):
            Button(String(localized: "Download"), action: actions.downloadModel)
                .buttonStyle(PrimaryButtonStyle(size: .compact))
                .accessibilityHint(String(localized: "Downloads the speech model from Hugging Face"))
        case .notDownloaded(.downloading(let received, let size)):
            HStack(spacing: 10) {
                GlacierBar(fraction: ModelSize.fraction(received: received, of: size)).frame(width: 72)
                Button(String(localized: "Cancel"), action: actions.cancelDownload)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityHint(String(localized: "Stops the download. Starting it again goes on from here."))
            }
        case .notDownloaded(.failed):
            HStack(spacing: 10) {
                StatusIndicator(.problem)
                Button(String(localized: "Try Again"), action: actions.downloadModel)
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
                    .accessibilityHint(String(localized: "Downloads the speech model again, from where it stopped"))
            }
        case .notDownloaded(.unavailable):
            StatusIndicator(.problem)
                .accessibilityHidden(true)
        }
    }

    /// The line under the model's name. The Neural Engine compiles the model for itself the first time, which can
    /// take minutes; the processor compiles nothing, so loading is quick every time.
    nonisolated static func detail(_ status: ModelStatus, on hardware: ModelHardware) -> String {
        switch (status, hardware) {
        case (.ready, .neuralEngine): String(localized: "On this Mac, on the Neural Engine.")
        case (.ready, .processor): String(localized: "On this Mac, on its processor.")
        case (.preparing, .neuralEngine):
            String(localized: "The first time on a Mac can take a few minutes. You can dictate meanwhile.")
        case (.preparing, .processor):
            String(localized: "Loading takes a moment each time the app opens. You can dictate meanwhile.")
        case (.failed(let problem), _): problem.explanation
        case (.notDownloaded(let download), _): ModelDownloadWords.detail(download)
        }
    }

    private var spokenState: String {
        switch status {
        case .ready: String(localized: "Ready. \(Self.detail(status, on: hardware))")
        case .preparing: String(localized: "Preparing. \(Self.detail(status, on: hardware))")
        case .failed(let problem): String(localized: "Unavailable. \(problem.explanation)")
        case .notDownloaded(.downloading):
            String(localized: "Downloading. \(Self.detail(status, on: hardware))")
        case .notDownloaded: Self.detail(status, on: hardware)
        }
    }
}

/// What the windows say about the model's download, the same in setup and on the General screen.
nonisolated enum ModelDownloadWords {
    /// One line for the download's state: its size and where from, how much has arrived, why it stopped, or that
    /// there is no model for this Mac.
    static func detail(_ download: ModelDownloadStatus) -> String {
        switch download {
        case .notStarted(let size):
            String(localized: "Not downloaded yet. \(ModelSize.words(size)), from Hugging Face.",
                   comment: "General: the model's size, such as 138 MB")
        case .downloading(let received, let size): ModelSize.progress(received: received, of: size)
        case .failed(let problem, let size): problem.explanation(size: size)
        case .unavailable: unavailable
        }
    }

    /// No build of the model fits this Mac.
    static var unavailable: String { String(localized: "There is no speech model for this Mac yet.") }
}

/// The microphone permission, its state in words, and the button that fixes it. Only a denied permission has a line
/// under its name.
struct MicrophonePermissionRow: View {
    let status: MicrophoneStatus
    let actions: GeneralActions
    /// Setup offers the fix in its own buttons, so its row only shows the state.
    var offersFix = true

    var body: some View {
        switch status {
        case .granted:
            PermissionRow(title: String(localized: "Microphone"), symbol: "mic", state: .granted)
        case .notDetermined:
            PermissionRow(title: String(localized: "Microphone"), symbol: "mic", state: .notAsked,
                          fix: offersFix ? (String(localized: "Allow…"), actions.requestMicrophone) : nil)
        case .denied:
            PermissionRow(title: String(localized: "Microphone"), symbol: "mic.slash",
                          detail: String(localized: "Off in System Settings, so nothing can be heard."), state: .missing,
                          fix: offersFix ? (String(localized: "Open System Settings"), actions.openMicrophoneSettings) : nil)
        }
    }
}

/// The Accessibility permission, its state in words, and the button that fixes it. Only a missing permission has a
/// line under its name.
struct AccessibilityPermissionRow: View {
    let status: AccessibilityStatus
    let actions: GeneralActions
    /// Setup offers the fix in its own buttons, so its row only shows the state.
    var offersFix = true

    var body: some View {
        switch status {
        case .granted:
            PermissionRow(title: String(localized: "Accessibility"), symbol: "accessibility", state: .granted)
        case .missing:
            PermissionRow(title: String(localized: "Accessibility"), symbol: "accessibility",
                          detail: String(localized: "Needed for the shortcuts and for pasting. Until then, text is left on the clipboard."),
                          state: .missing,
                          fix: offersFix ? (String(localized: "Open System Settings"), actions.openAccessibilitySettings) : nil)
        }
    }
}

/// A permission's row: its glyph, its name, a line on what is wrong when it is not allowed, then its state or the
/// button that fixes it.
struct PermissionRow: View {
    enum State { case granted, notAsked, missing }

    let title: String
    let symbol: String
    var detail: String?
    let state: State
    var fix: (String, () -> Void)?

    var body: some View {
        HStack(spacing: Metrics.glyphGap) {
            RowGlyph(symbol)
            RowWords(title: title, detail: detail)
            Spacer(minLength: 12)
            if state == .missing { StatusIndicator(.problem) }
            if let fix {
                Button(fix.0, action: fix.1)
                    .buttonStyle(PrimaryButtonStyle(size: .compact))
                    .accessibilityLabel(fix.0)
                    .accessibilityHint(String(localized: "\(title) permission"))
            } else {
                HStack(spacing: 6) {
                    if state == .notAsked { StatusIndicator(.neutral) }
                    if state == .granted { StatusIndicator(.ready) }
                    Text(spokenState).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                }
                .accessibilityHidden(true)
            }
        }
        .rowPadding()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(spokenState)
    }

    private var spokenState: String {
        switch state {
        case .granted: String(localized: "Allowed")
        case .notAsked: String(localized: "Not asked yet")
        case .missing: String(localized: "Not allowed")
        }
    }
}

/// The microphone menu: the system default first, then each device by name.
private struct MicrophonePicker: View {
    @Bindable var model: GeneralModel

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { model.selectedMicrophoneID },
                                      set: { id in
                                          model.selectedMicrophoneID = id
                                          model.actions.selectMicrophone(id)
                                      })) {
                Text(defaultTitle).tag(String?.none)
                if !model.microphones.isEmpty { Divider() }
                ForEach(model.microphones) { microphone in
                    Text(microphone.name).tag(Optional(microphone.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MenuLabel(title: currentTitle,
                      caption: model.selectedMicrophoneID == nil ? String(localized: "Default") : nil)
        }
        .menuStyle(.button)
        .buttonStyle(MenuLabelStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Microphone"))
        .accessibilityValue(model.selectedMicrophoneID == nil ? defaultTitle : currentTitle)
    }

    private var defaultTitle: String {
        if let name = model.defaultMicrophoneName { return String(localized: "System default (\(name))") }
        return String(localized: "System default")
    }

    /// The chosen device's name; for the default, its name with "Default" beside it.
    private var currentTitle: String {
        guard let id = model.selectedMicrophoneID else {
            return model.defaultMicrophoneName ?? String(localized: "System default")
        }
        return model.microphones.first { $0.id == id }?.name ?? defaultTitle
    }
}

/// A pop-up menu's face on the island's surface: its value and a chevron.
struct MenuLabel: View {
    let title: String
    /// A quieter word before the value, such as "Default".
    var caption: String?

    var body: some View {
        HStack(spacing: 6) {
            if let caption {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryInk)
            }
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.ink)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 26)
    }
}

/// The surface under a `MenuLabel`.
struct MenuLabelStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuLabelBody(configuration: configuration)
    }
}

private struct MenuLabelBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(Capsule().fill(hovering ? Color.white.opacity(0.07) : .clear))
            .islandSurface()
            .contentShape(Capsule())
            .focusRing(Pill(), isFocused: isFocused)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}
