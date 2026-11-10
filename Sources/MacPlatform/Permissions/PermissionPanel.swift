import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import SwiftUI

// The drag card itself. It opens the permission's pane in System Settings,
// waits for the window to settle, flies from the Grant Access button and docks
// below the window (or inside its empty lower area), with its app row under
// the Privacy list's column. The row drags this copy of the app, the bundle
// that holds the grant. A drop is only a hint: the grant is read from
// AXIsProcessTrusted, and the card returns if it is still missing.
//
// Settings is followed through the window server: only its windows' bounds
// and count are read (no titles or contents), which needs no Screen Recording
// or Accessibility access. Nothing is logged or stored.
//
// Adapted from Scrawl and AskForPermission; see PermissionPanelCore.swift for
// attribution, and ThirdPartyNotices.md.

extension PermissionPanel {
    static let settingsBundleID = "com.apple.systempreferences"

    @MainActor static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    @MainActor static func appKit(fromQuartz r: CGRect) -> NSRect {
        appKit(fromQuartz: r, primaryHeight: primaryHeight)
    }

    /// `dock` for a window given in CGWindow coordinates, on the screen holding it.
    @MainActor static func dockFrame(settingsQuartz: CGRect, layout: Layout) -> NSRect {
        let settings = appKit(fromQuartz: settingsQuartz)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: settings.midX, y: settings.midY)) }
            ?? NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main
        return dock(settings: settings, visible: screen?.visibleFrame ?? settings, layout: layout).frame
    }
}

// MARK: - Card

extension PermissionPanel {
    @MainActor
    @Observable
    final class CardModel {
        enum Phase { case instruction, waiting, granted }
        var phase = Phase.instruction
        var hovering = false
        var dragging = false
        var contentOpacity: Double = 1
        var contentScale: Double = 1
        var contentBlur: Double = 0
        @ObservationIgnored var onBack: () -> Void = {}
    }

    struct CardContent: View {
        let model: CardModel
        let style: PermissionCardStyle
        let paneTitle: String
        let layout: Layout
        let appName: String
        let icon: NSImage
        let interactive: Bool
        let dragView: () -> NSView

        var body: some View {
            ZStack(alignment: .topLeading) {
                instruction
                    .frame(width: layout.rowWidth, height: layout.instructionHeight, alignment: .leading)
                    .offset(x: layout.gutter, y: layout.top)
                appRow
                    .frame(width: layout.rowWidth, height: layout.rowHeight)
                    .offset(x: layout.gutter, y: layout.rowY)
                BackButton(style: style, action: { model.onBack() })
                    .frame(width: 28, height: 28)
                    .offset(x: (layout.gutter - 28) / 2 + 1, y: layout.rowY + (layout.rowHeight - 28) / 2)
                    .opacity(model.phase == .granted ? 0 : 1)
            }
            .frame(width: layout.cardSize.width, height: layout.cardSize.height, alignment: .topLeading)
            .scaleEffect(model.contentScale)
            .blur(radius: model.contentBlur)
            .opacity(model.contentOpacity)
            .animation(.spring(duration: 0.3, bounce: 0), value: model.phase)
            .animation(.spring(duration: 0.25, bounce: 0), value: model.hovering)
            .animation(.spring(duration: 0.25, bounce: 0), value: model.dragging)
        }

        private var instruction: some View {
            HStack(spacing: 0) {
                ZStack {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(style.ink.color)
                        .opacity(model.phase == .granted ? 0 : 1)
                        .scaleEffect(model.phase == .granted ? 0.6 : 1)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(style.surface.color, style.done.color)
                        .opacity(model.phase == .granted ? 1 : 0)
                        .scaleEffect(model.phase == .granted ? 1 : 0.6)
                }
                .frame(width: layout.icon)
                .padding(.leading, layout.iconLeading)
                .padding(.trailing, layout.textLeading - layout.iconLeading - layout.icon)
                ZStack(alignment: .leading) {
                    Text("Drag \(emphasized(appName)) to the list above to allow \(emphasized(paneTitle))",
                         comment: "The drag card's instruction: the app's name, then the Settings pane's.")
                        .opacity(model.phase == .granted ? 0 : 1)
                        .blur(radius: model.phase == .granted ? 3 : 0)
                    Text("\(emphasized(appName)) is allowed", comment: "The drag card once access is granted.")
                        .opacity(model.phase == .granted ? 1 : 0)
                        .blur(radius: model.phase == .granted ? 0 : 3)
                }
                .foregroundStyle(style.ink.color.opacity(style.secondaryInkAlpha))
                .font(.system(size: 13))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }

        private func emphasized(_ text: String) -> Text {
            Text(text).foregroundStyle(style.ink.color).fontWeight(.medium)
        }

        private var appRow: some View {
            let shape = RoundedRectangle(cornerRadius: layout.rowRadius, style: .continuous)
            let lifted = model.dragging
            return HStack(spacing: 0) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.icon, height: layout.icon)
                    .padding(.leading, layout.iconLeading)
                    .padding(.trailing, layout.textLeading - layout.iconLeading - layout.icon)
                Text(appName)
                    .font(.system(size: 13))
                    .foregroundStyle(style.ink.color)
                Spacer(minLength: 0)
            }
            .opacity(lifted ? 0.28 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(style.row.color))
            .background(shape.fill(style.ink.color.opacity(model.hovering && !lifted ? 0.06 : 0)))
            .overlay(shape.strokeBorder(style.edge.color, lineWidth: 0.5))
            .overlay {
                if interactive {
                    DragHost(make: dragView)
                }
            }
            .opacity(model.phase == .granted ? 0.5 : 1)
        }
    }

    struct BackButton: View {
        let style: PermissionCardStyle
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(style.ink.color.opacity(hovering ? 1 : style.secondaryInkAlpha))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(style.ink.color.opacity(hovering ? 0.12 : 0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("Back", comment: "Closes the drag card."))
            .accessibilityLabel(Text("Back", comment: "Closes the drag card."))
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.25, bounce: 0), value: hovering)
        }
    }

    struct DragHost: NSViewRepresentable {
        let make: () -> NSView
        func makeNSView(context _: Context) -> NSView { make() }
        func updateNSView(_: NSView, context _: Context) {}
    }

    /// The draggable app row's hit area. SwiftUI draws the row; this view is
    /// the NSDraggingSource, and its pasteboard item is the app bundle's file URL.
    final class DragSource: NSView, NSDraggingSource {
        let appURL: URL
        let appName: String
        let icon: NSImage
        let model: CardModel
        let style: PermissionCardStyle
        var onEnded: (NSDragOperation) -> Void = { _ in }
        private var down: NSEvent?

        init(appURL: URL, appName: String, icon: NSImage, model: CardModel, style: PermissionCardStyle) {
            self.appURL = appURL
            self.appName = appName
            self.icon = icon
            self.model = model
            self.style = style
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with _: NSEvent) { model.hovering = true }
        override func mouseExited(with _: NSEvent) { model.hovering = false }
        override func mouseDown(with event: NSEvent) { down = event }
        override func mouseUp(with _: NSEvent) { down = nil }

        override func mouseDragged(with event: NSEvent) {
            guard let down else { return }
            let distance = hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y)
            guard distance >= 3 else { return }
            self.down = nil
            let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
            item.setDraggingFrame(bounds, contents: dragImage())
            let session = beginDraggingSession(with: [item], event: down, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
            model.dragging = true
        }

        /// The row as the list will show it: opaque, so it reads over any window it crosses.
        private func dragImage() -> NSImage {
            let size = bounds.size
            let scale = window?.backingScaleFactor ?? 2
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return icon }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let rect = NSRect(origin: .zero, size: size)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 9, yRadius: 9)
            style.row.nsColor.withAlphaComponent(0.96).setFill()
            path.fill()
            style.edge.nsColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()
            icon.draw(in: NSRect(x: 10, y: (size.height - 26) / 2, width: 26, height: 26))
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
                                                             .foregroundColor: style.ink.nsColor]
            let textHeight = (appName as NSString).size(withAttributes: attributes).height
            (appName as NSString).draw(at: NSPoint(x: 46, y: (size.height - textHeight) / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            return image
        }

        func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation { .copy }

        func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation: NSDragOperation) {
            model.dragging = false
            model.hovering = false
            onEnded(operation)
        }
    }

    /// Frosts the glass so list rows behind the card don't read through its text.
    final class Frost: NSView {
        var color = NSColor.black
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.backgroundColor = color.withAlphaComponent(0.62).cgColor
        }
    }

    /// One card surface: a two-layer shadow, frosted Liquid Glass, and the
    /// content clipped to it. The flight and the docked panel use the same
    /// class so the hand-off is pixel for pixel.
    final class CardSurface: NSView {
        let glass = NSGlassEffectView()
        let clip = NSView()
        let frost = Frost()
        let content: NSView
        let contentSize: NSSize
        private let contact = CALayer()
        private let ambient = CALayer()

        init(content: NSView, size: NSSize, frostColor: NSColor) {
            self.content = content
            self.contentSize = size
            super.init(frame: NSRect(origin: .zero, size: size))
            wantsLayer = true
            layer?.masksToBounds = false
            for shadow in [ambient, contact] {
                shadow.shadowColor = NSColor.black.cgColor
                shadow.shadowOffset = .zero
                layer?.addSublayer(shadow)
            }
            contact.shadowRadius = 1.5
            contact.shadowOffset = CGSize(width: 0, height: -0.5)
            ambient.shadowOffset = CGSize(width: 0, height: -8)
            glass.style = .regular
            addSubview(glass)
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            clip.layer?.cornerCurve = .continuous
            addSubview(clip)
            frost.color = frostColor
            frost.wantsLayer = true
            frost.autoresizingMask = [.width, .height]
            clip.addSubview(frost)
            content.frame = NSRect(origin: .zero, size: size)
            clip.addSubview(content)
            apply(size: size, radius: 18, lift: 0)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

        /// `lift` 0 is docked; 1 is the top of the arc, with a deeper, softer shadow.
        func apply(size: NSSize, radius: CGFloat, lift: CGFloat) {
            let bounds = NSRect(origin: .zero, size: size)
            glass.frame = bounds
            glass.cornerRadius = radius
            clip.frame = bounds
            clip.layer?.cornerRadius = radius
            frost.frame = bounds
            content.frame.origin = NSPoint(x: (size.width - contentSize.width) / 2, y: (size.height - contentSize.height) / 2)
            let path = CGPath(roundedRect: bounds, cornerWidth: min(radius, size.width / 2), cornerHeight: min(radius, size.height / 2), transform: nil)
            for shadow in [ambient, contact] {
                shadow.frame = bounds
                shadow.shadowPath = path
            }
            contact.shadowOpacity = Float(0.3 - 0.1 * lift)
            ambient.shadowOpacity = Float(0.32 + 0.14 * lift)
            ambient.shadowRadius = 18 + 14 * lift
            ambient.shadowOffset = CGSize(width: 0, height: -8 - 12 * lift)
        }
    }

    /// Borderless, non-activating, on every Space (Stage Manager moves ordinary windows aside).
    final class OverlayPanel: NSPanel {
        init(frame: NSRect, level: NSWindow.Level) {
            super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            isFloatingPanel = true
            self.level = level
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            hidesOnDeactivate = false
            isReleasedWhenClosed = false
            becomesKeyOnlyIfNeeded = true
            animationBehavior = .none
            // Sorello is always dark, whatever the system appearance.
            appearance = NSAppearance(named: .darkAqua)
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }

        /// The flight's window spans the arc, which can rise past the menu bar.
        /// AppKit would push it down onto the screen, and the card with it.
        override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect { frameRect }
    }
}

// MARK: - Settings window

extension PermissionPanel {
    /// Follows the System Settings window through the window server. Matches
    /// its owner by bundle identifier, so a localized name doesn't matter.
    @MainActor
    enum SettingsWindow {
        static func windows() -> [[String: Any]] {
            let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: PermissionPanel.settingsBundleID).map(\.processIdentifier))
            guard !pids.isEmpty,
                  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            else { return [] }
            return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t).map(pids.contains) ?? false }
        }

        /// The largest ordinary Settings window: its number and CGWindow bounds.
        static func main() -> (id: CGWindowID, frame: CGRect)? {
            var best: (id: CGWindowID, frame: CGRect)?
            for window in windows() {
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      let id = window[kCGWindowNumber as String] as? CGWindowID,
                      let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds),
                      frame.width >= 300, frame.height >= 200
                else { continue }
                if best.map({ frame.width * frame.height > $0.frame.width * $0.frame.height }) ?? true {
                    best = (id, frame)
                }
            }
            return best
        }

        /// One window's current bounds, cheaper than listing every window.
        static func frame(of id: CGWindowID) -> CGRect? {
            var value = UnsafeRawPointer(bitPattern: UInt(id))
            guard value != nil,
                  let ids = CFArrayCreate(nil, &value, 1, nil),
                  let info = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
                  let window = info.first,
                  (window[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }

        /// Sheets and alerts (the authentication prompt) add windows; their
        /// count dropping back means one was dismissed.
        static func count() -> Int { windows().count }
    }
}

// MARK: - Controller

extension PermissionPanel {
    /// One Accessibility drag card, from opening System Settings to the grant or a cancel. It opens the
    /// Accessibility pane, flies a card out of the Grant Access button and docks it by the Settings window; the
    /// user drags the app's row into the list. The grant is read from `AXIsProcessTrusted`, never assumed from a
    /// drop. `onFinish` is called once, with whether access was granted.
    @MainActor
    public final class Controller: NSObject {
        let permission = PrivacyPermission.accessibility
        /// The Grant Access button's frame on screen, where the flight starts.
        let source: NSRect?
        let appURL: URL
        let reduceMotion: Bool
        let appName: String
        let icon: NSImage
        let style: PermissionCardStyle
        public var onFinish: (Bool) -> Void = { _ in }

        private static let margin: CGFloat = 48
        /// Gives up on a card left open this long.
        private static let lifetime: TimeInterval = 600

        private var layout = Layout(settingsWidth: 740)
        private var panel: OverlayPanel?
        private var panelSurface: CardSurface?
        private let panelModel = CardModel()
        private var flight: Flight?
        private var settingsID: CGWindowID?
        private var settingsFrame: CGRect?
        private var missingSince: Date?
        private var trackTimer: Timer?
        private var pollTimer: Timer?
        private var dropRace: DropRace?
        private var isFading = false
        private var finished = false
        private let startedAt = Date()

        /// `source` is the Grant Access button's frame on screen (AppKit coordinates), or nil to fade the card in
        /// where it docks. `appURL` is the bundle the row drags, the one that holds the grant; `appName` is read
        /// from it unless given.
        public init(source: CGRect?, style: PermissionCardStyle, appURL: URL = Bundle.main.bundleURL,
                    appName: String? = nil) {
            self.source = source
            self.style = style
            self.appURL = appURL
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self.appName = appName ?? Bundle(url: appURL)?.appDisplayName ?? Bundle.main.appDisplayName
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 64, height: 64)
            self.icon = icon
        }

        /// Opens System Settings and shows the card. With access already granted it finishes at once.
        public func start() {
            if isGranted { return finish(granted: true, animated: false) }
            permission.openSettings()
            waitForSettings(deadline: Date().addingTimeInterval(6), firstSeen: nil, last: nil)
        }

        /// Fades the card out without a grant, as when another card replaces it.
        public func cancel() { cancel(flyBack: false) }

        private var isGranted: Bool { AXIsProcessTrusted() }

        // MARK: Flow

        /// Waits for the Settings window to stop moving: two equal samples
        /// 100 ms apart, or 1.2 s after it first appeared (a cold launch).
        private func waitForSettings(deadline: Date, firstSeen: Date?, last: CGRect?) {
            guard !finished else { return }
            let now = Date()
            if let window = SettingsWindow.main() {
                if let last, window.frame.integral == last.integral { return dock(window.id, window.frame) }
                if let firstSeen, now.timeIntervalSince(firstSeen) >= 1.2 { return dock(window.id, window.frame) }
                after(0.1) { [weak self] in
                    self?.waitForSettings(deadline: deadline, firstSeen: firstSeen ?? now, last: window.frame)
                }
                return
            }
            // Settings is open on the pane even if no card appears.
            if now > deadline { return finish(granted: false, animated: false) }
            after(0.1) { [weak self] in
                self?.waitForSettings(deadline: deadline, firstSeen: nil, last: nil)
            }
        }

        private func dock(_ id: CGWindowID, _ frame: CGRect) {
            settingsID = id
            settingsFrame = frame
            layout = Layout(settingsWidth: frame.width)
            let target = dockFrame(settingsQuartz: frame, layout: layout)
            buildPanel(at: target)
            if reduceMotion || source == nil {
                fadeIn()
            } else if let source {
                fly(from: source, to: target)
            }
        }

        private func docked() {
            startTracking()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }

        // MARK: Panel

        private func makeSurface(model: CardModel, interactive: Bool) -> CardSurface {
            let dragSource = DragSource(appURL: appURL, appName: appName, icon: icon, model: model, style: style)
            dragSource.onEnded = { [weak self] operation in self?.dragEnded(operation) }
            let content = CardContent(
                model: model, style: style, paneTitle: permission.settingsTitle, layout: layout, appName: appName,
                icon: icon, interactive: interactive, dragView: { dragSource }
            )
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            return CardSurface(content: host, size: layout.cardSize, frostColor: style.surface.nsColor)
        }

        private func buildPanel(at card: NSRect) {
            panelModel.onBack = { [weak self] in self?.cancel(flyBack: true) }
            let surface = makeSurface(model: panelModel, interactive: true)
            let frame = card.insetBy(dx: -Self.margin, dy: -Self.margin)
            let panel = OverlayPanel(frame: frame, level: .floating)
            let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
            surface.frame.origin = NSPoint(x: Self.margin, y: Self.margin)
            root.addSubview(surface)
            panel.contentView = root
            self.panel = panel
            panelSurface = surface
        }

        private func moveDock(to card: NSRect) {
            panel?.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
        }

        private func fadeIn() {
            guard let panel else { return }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                panel.animator().alphaValue = 1
            }
            docked()
        }

        private func fly(from source: NSRect, to target: NSRect) {
            let model = CardModel()
            model.contentOpacity = 0
            let surface = makeSurface(model: model, interactive: false)
            let flight = Flight(source: source, target: target, spring: flightSpring, surface: surface, model: model, reverse: false)
            self.flight = flight
            flight.start { [weak self] in
                guard let self, let panel = self.panel else { return }
                panel.orderFrontRegardless()
                // The overlay's card sits exactly over the panel's; drop it once the panel has drawn.
                after(0.05) { [weak self] in
                    flight.close()
                    self?.flight = nil
                }
                self.docked()
            }
        }

        private func flyBack(then done: @escaping @MainActor () -> Void) {
            guard let panel, let surface = panelSurface else { return done() }
            let card = NSRect(origin: NSPoint(x: panel.frame.minX + Self.margin, y: panel.frame.minY + Self.margin), size: surface.frame.size)
            guard !reduceMotion, let source else { return fadeOut(then: done) }
            let model = CardModel()
            model.phase = panelModel.phase
            let flyer = makeSurface(model: model, interactive: false)
            let flight = Flight(source: source, target: card, spring: returnSpring, surface: flyer, model: model, reverse: true)
            self.flight = flight
            flight.onFirstFrame = { panel.orderOut(nil) }
            flight.start { [weak self] in
                flight.close()
                self?.flight = nil
                done()
            }
        }

        private func fadeOut(then done: @escaping @MainActor () -> Void) {
            guard let panel, panel.isVisible else { return done() }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration * 0.8
                panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    done()
                }
            }
            if !reduceMotion {
                withAnimation(.spring(duration: fadeDuration * 0.8, bounce: 0)) {
                    panelModel.contentScale = 0.96
                    panelModel.contentBlur = 3
                }
            }
        }

        private func setPanelAlpha(_ alpha: CGFloat) {
            guard let panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fadeDuration
                panel.animator().alphaValue = alpha
            }
        }

        // MARK: Tracking

        private func startTracking() {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.track() }
            }
            RunLoop.main.add(timer, forMode: .common)
            trackTimer = timer
        }

        /// The card follows Settings 1:1 (the user is moving it) and steps
        /// aside while another app is in front.
        private func track() {
            guard !finished, let panel else { return }
            var frame = settingsID.flatMap(SettingsWindow.frame(of:))
            if frame == nil, let window = SettingsWindow.main() {
                settingsID = window.id
                frame = window.frame
            }
            guard let frame else {
                missingSince = missingSince ?? Date()
                if let missingSince, Date().timeIntervalSince(missingSince) > 0.6 { cancel(flyBack: false) }
                return
            }
            missingSince = nil
            if frame != settingsFrame {
                settingsFrame = frame
                moveDock(to: dockFrame(settingsQuartz: frame, layout: layout))
            }
            if dropRace == nil, flight == nil {
                let front = NSWorkspace.shared.frontmostApplication
                let ours = front?.bundleIdentifier == settingsBundleID
                    || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                    || panelModel.dragging
                let alpha: CGFloat = ours ? 1 : 0
                if panel.alphaValue != alpha, !isFading {
                    isFading = true
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = fadeDuration
                        panel.animator().alphaValue = alpha
                    } completionHandler: { [weak self] in
                        MainActor.assumeIsolated { self?.isFading = false }
                    }
                }
            }
            if Date().timeIntervalSince(startedAt) > Self.lifetime { cancel(flyBack: false) }
        }

        // MARK: Grant

        private func poll() {
            guard !finished else { return }
            if isGranted { return finish(granted: true, animated: true) }
            guard var race = dropRace else { return }
            let ended = race.observe(settingsWindowCount: SettingsWindow.count(), at: Date())
            dropRace = ended ? nil : race
            if ended {
                // Give Settings a moment to record the grant before showing the card again.
                after(0.2) { [weak self] in
                    guard let self, !self.finished, self.dropRace == nil else { return }
                    if self.isGranted { return self.finish(granted: true, animated: true) }
                    self.panelModel.phase = .instruction
                    self.setPanelAlpha(1)
                }
            }
        }

        /// A drop is a hint, never the answer: step out of the way of whatever
        /// Settings shows, and come back if the grant isn't there.
        private func dragEnded(_ operation: NSDragOperation) {
            guard !finished, !operation.isEmpty else { return }
            dropRace = DropRace(droppedAt: Date(), settingsWindowCount: SettingsWindow.count())
            panelModel.phase = .waiting
            setPanelAlpha(0)
            poll()
        }

        // MARK: Ending

        private func cancel(flyBack back: Bool) {
            guard !finished else { return }
            finished = true
            stopTimers()
            let done: @MainActor () -> Void = { [weak self] in self?.close(granted: false) }
            if back { flyBack(then: done) } else { fadeOut(then: done) }
        }

        private func finish(granted: Bool, animated: Bool) {
            guard !finished else { return }
            finished = true
            stopTimers()
            guard animated, panel != nil else { return close(granted: granted) }
            panelModel.phase = .granted
            setPanelAlpha(1)
            after(0.9) { [weak self] in
                self?.fadeOut { self?.close(granted: granted) }
            }
        }

        private func close(granted: Bool) {
            flight?.close()
            flight = nil
            panel?.orderOut(nil)
            panel = nil
            panelSurface = nil
            let onFinish = onFinish
            self.onFinish = { _ in }
            onFinish(granted)
        }

        private func stopTimers() {
            trackTimer?.invalidate()
            trackTimer = nil
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}

// MARK: - Flight

extension PermissionPanel {
    /// The card in the air: one overlay window over the whole path, the card
    /// moved inside it on the display's clock. The path is a quadratic Bézier
    /// through a point above both ends; the size runs ahead of the path (width
    /// first), the corners go from the button's to the card's, and the content
    /// resolves (opacity, 0.96 → 1 scale, 3 px → 0 blur) as the card reaches
    /// full size.
    @MainActor
    final class Flight: NSObject {
        let source: NSRect
        let target: NSRect
        let spring: Spring
        let surface: CardSurface
        let model: CardModel
        let reverse: Bool
        let window: OverlayPanel
        var onFirstFrame: () -> Void = {}
        private var done: @MainActor () -> Void = {}
        private var link: CADisplayLink?
        private var startTime: CFTimeInterval = 0
        private let control: CGPoint

        init(source: NSRect, target: NSRect, spring: Spring, surface: CardSurface, model: CardModel, reverse: Bool) {
            self.source = source
            self.target = target
            self.spring = spring
            self.surface = surface
            self.model = model
            self.reverse = reverse
            // The card's centre stays far enough below the top of the screen for the card to fit.
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: source.midX, y: source.midY)) } ?? NSScreen.main
            let ceiling = (screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude) - target.height / 2 - 8
            control = PermissionPanel.flightControl(source: source, target: target, ceiling: ceiling)
            let bounds = source.union(target).union(NSRect(x: control.x, y: control.y, width: 1, height: 1)).insetBy(dx: -64, dy: -64)
            window = OverlayPanel(frame: bounds, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
            window.ignoresMouseEvents = true
            let root = NSView(frame: NSRect(origin: .zero, size: bounds.size))
            window.contentView = root
            root.addSubview(surface)
            super.init()
        }

        func start(done: @escaping @MainActor () -> Void) {
            self.done = done
            step(at: 0)
            window.orderFrontRegardless()
            onFirstFrame()
            onFirstFrame = {}
            startTime = CACurrentMediaTime()
            let link = surface.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        /// Stops the flight and lets go of its completion, whose callers capture the flight itself.
        func close() {
            link?.invalidate()
            link = nil
            done = {}
            onFirstFrame = {}
            window.orderOut(nil)
        }

        @objc private func tick(_ link: CADisplayLink) {
            let t = link.targetTimestamp - startTime
            if t >= spring.settleTime {
                step(at: spring.settleTime)
                link.invalidate()
                self.link = nil
                let done = self.done
                self.done = {}
                done()
                return
            }
            step(at: t)
        }

        private func step(at t: Double) {
            // Progress from the source (0) to the dock (1); reversed flights run it backwards.
            let path = spring.value(t)
            let width = Spring(duration: spring.duration * PermissionPanel.widthLead, bounce: spring.bounce).value(t)
            let p = reverse ? 1 - path : path
            let w = reverse ? 1 - width : width
            let start = CGPoint(x: source.midX, y: source.midY)
            let end = CGPoint(x: target.midX, y: target.midY)
            let u = 1 - p
            let center = CGPoint(
                x: u * u * start.x + 2 * u * p * control.x + p * p * end.x,
                y: u * u * start.y + 2 * u * p * control.y + p * p * end.y
            )
            let size = NSSize(
                width: source.width + (target.width - source.width) * w,
                height: source.height + (target.height - source.height) * p
            )
            let startRadius = source.height / 2
            let radius = startRadius + (18 - startRadius) * min(w, p)
            let origin = window.frame.origin
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.frame = NSRect(x: center.x - size.width / 2 - origin.x, y: center.y - size.height / 2 - origin.y, width: size.width, height: size.height)
            surface.apply(size: size, radius: radius, lift: 4 * p * (1 - p))
            // Lift off the button over the first stretch; land on it fading on the way back.
            surface.alphaValue = smoothstep(0, 0.14, p)
            let resolve = smoothstep(reverse ? 0.5 : 0.3, reverse ? 0.9 : 0.85, min(w, p))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.contentOpacity = resolve
                model.contentScale = 0.96 + 0.04 * resolve
                model.contentBlur = 3 * (1 - resolve)
            }
            CATransaction.commit()
        }

        private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
    }
}

// MARK: - Timing

/// Runs `body` on the main actor after `seconds`.
@MainActor
private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(seconds))
        body()
    }
}
