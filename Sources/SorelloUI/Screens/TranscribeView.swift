import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Transcribe File window (ARCHITECTURE.md, section 8, "Windows"): one audio or video file turned into text. It
/// draws `TranscribeModel.state` and reports what the user does through its actions. A file dropped anywhere on the
/// window is taken only while the window takes files, and only when exactly one file is dragged; the drop area, or
/// in a window already showing a file the window's edge, lights up while such a file is over it. A long transcript
/// scrolls inside its field and never changes the window's size.
public struct TranscribeView: View {
    @Bindable private var model: TranscribeModel
    @State private var fileIsOver = false
    /// Holds the drop area lit or unlit, for the snapshots; nil follows the drag.
    private let pinnedFileOver: Bool?

    /// The window drawn from `model`.
    public init(model: TranscribeModel) {
        self.init(model: model, fileOver: nil)
    }

    /// The window with a file held over it, or not, whatever the pointer does: for the snapshots.
    init(model: TranscribeModel, fileOver: Bool?) {
        self.model = model
        pinnedFileOver = fileOver
    }

    private var lit: Bool { (pinnedFileOver ?? fileIsOver) && model.state.takesFiles }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(TranscribeWords.title)
                .displayType(.screenTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let name = model.state.fileName {
                FileLine(name: name)
            }
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, Metrics.titleBarClearance)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.screen)
        .overlay {
            // A window that already shows a file lights its edge, since it has no drop area to light.
            if lit && model.state != .empty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDrop(of: [.fileURL], delegate: FileDrop(model: model, isOver: $fileIsOver))
    }

    // MARK: The stage

    @ViewBuilder
    private var stage: some View {
        switch model.state {
        case .empty:
            DropArea(lit: lit, choose: model.actions.chooseFile)
        case .preparing:
            ProgressStage(fraction: nil, words: TranscribeWords.preparing,
                          spokenLabel: TranscribeWords.preparing, spokenValue: nil)
        case .transcribing(_, let read, let length):
            let words = TranscribeWords.progress(read: read, length: length)
            ProgressStage(fraction: TranscribeWords.fraction(read: read, length: length), words: words,
                          spokenLabel: String(localized: "Transcribing"), spokenValue: words)
        case .done(_, let text):
            TranscriptField(text: text)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Theme.edge, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        case .nothingHeard:
            MessageStage(symbol: "waveform.slash", tint: Theme.secondaryInk, title: TranscribeWords.nothingHeard,
                         detail: nil)
        case .failed(_, let reason):
            MessageStage(symbol: "exclamationmark.triangle.fill", tint: Theme.ember,
                         title: TranscribeWords.reason(reason, appName: model.appName),
                         detail: TranscribeWords.detail(reason))
        }
    }

    // MARK: The buttons

    @ViewBuilder
    private var footer: some View {
        switch model.state {
        case .empty:
            EmptyView()
        case .preparing, .transcribing:
            HStack {
                Spacer(minLength: 0)
                Button(String(localized: "Cancel"), action: model.actions.cancel)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(String(localized: "Stops transcribing the file"))
            }
        case .done:
            HStack(spacing: 10) {
                chooseFile(primary: false)
                Spacer(minLength: 0)
                Button(action: model.actions.copy) {
                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint(String(localized: "Puts the text on the clipboard"))
                Button(action: model.actions.save) {
                    Label(String(localized: "Save…"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityHint(String(localized: "Saves the text as a plain text file"))
            }
        case .nothingHeard:
            HStack {
                Spacer(minLength: 0)
                chooseFile(primary: true)
            }
        case .failed(_, let reason):
            HStack(spacing: 10) {
                if let remedy = reason.remedy {
                    chooseFile(primary: false)
                    Spacer(minLength: 0)
                    Button(remedy.title) { model.actions.perform(remedy) }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityHint(remedy.hint)
                } else {
                    Spacer(minLength: 0)
                    chooseFile(primary: true)
                }
            }
        }
    }

    @ViewBuilder
    private func chooseFile(primary: Bool) -> some View {
        let button = Button(String(localized: "Choose File…"), action: model.actions.chooseFile)
            .accessibilityHint(String(localized: "Chooses an audio or video file to transcribe"))
        if primary {
            button.buttonStyle(PrimaryButtonStyle())
        } else {
            button.buttonStyle(QuietButtonStyle())
        }
    }
}

/// The file's name under the title, cut in the middle when it is long so its extension still shows.
private struct FileLine: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.secondaryInk)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "File"))
        .accessibilityValue(name)
    }
}

/// The empty window's drop area: a dashed outline round the words and Choose File…, which lights up while a file the
/// window would take is over it.
private struct DropArea: View {
    let lit: Bool
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(lit ? Theme.ink : Theme.secondaryInk)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(TranscribeWords.dropPrompt)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Button(String(localized: "Choose File…"), action: choose)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 6)
                .accessibilityHint(String(localized: "Chooses an audio or video file to transcribe"))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(lit ? Theme.hover : .clear))
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.white.opacity(lit ? 0.85 : 0.2),
                          style: StrokeStyle(lineWidth: lit ? 2 : 1, dash: lit ? [] : [6, 5])))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TranscribeWords.dropPrompt)
    }
}

/// The bar, filled or travelling, and the words under it.
private struct ProgressStage: View {
    let fraction: Double?
    let words: String?
    let spokenLabel: String
    let spokenValue: String?

    var body: some View {
        VStack(spacing: 12) {
            GlacierBar(fraction: fraction)
                .frame(maxWidth: 300)
            // The line keeps its height while the length is not known, so nothing moves when the words arrive.
            Text(words ?? " ")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(radius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(spokenValue ?? "")
    }
}

/// A symbol and one line, with a second line in secondary ink when there is one: no speech heard, or a failure.
private struct MessageStage: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(tint)
                .padding(.bottom, 2)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(radius: 16)
        .accessibilityElement(children: .combine)
    }
}

/// The transcript: AppKit's text view, which can be selected and copied but not edited, and scrolls however long the
/// text is without asking the window for more room.
private struct TranscriptField: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 10, height: 12)
            view.insertionPointColor = .white
            view.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.25),
                                           .foregroundColor: NSColor.white]
            view.setAccessibilityLabel(String(localized: "Transcript"))
            show(text, in: view)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        show(text, in: view)
        view.scrollToBeginningOfDocument(nil)
    }

    /// Puts `text` in the view in white, with a little room between its lines.
    private func show(_ text: String, in view: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]))
    }
}

/// Takes a file dropped on the window: exactly one file's address, and only while the window takes files. Anything
/// else is refused before it is dropped, so the drop area does not light up for it.
private struct FileDrop: DropDelegate {
    let model: TranscribeModel
    @Binding var isOver: Bool

    func validateDrop(info: DropInfo) -> Bool {
        TranscribeDrop.accepts(itemCount: info.itemProviders(for: [.item]).count,
                               fileCount: info.itemProviders(for: [.fileURL]).count, state: model.state)
    }

    func dropEntered(info: DropInfo) {
        isOver = validateDrop(info: info)
    }

    func dropExited(info: DropInfo) {
        isOver = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isOver = validateDrop(info: info)
        return DropProposal(operation: isOver ? .copy : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isOver = false
        guard validateDrop(info: info), let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        let model = self.model
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            Task { @MainActor in
                // The window may have taken another file since the drop began.
                if model.state.takesFiles { model.actions.dropFile(url) }
            }
        }
        return true
    }
}

/// Which drags the window takes (ARCHITECTURE.md, section 8, "Windows").
nonisolated enum TranscribeDrop {
    /// True when the drag is exactly one item, that item is a file's address, and the window takes files now.
    static func accepts(itemCount: Int, fileCount: Int, state: TranscribeState) -> Bool {
        itemCount == 1 && fileCount == 1 && state.takesFiles
    }
}
