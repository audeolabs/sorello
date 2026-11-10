import SwiftUI

/// A notice the About screen lists: a title, one line on what it covers, and the full text the app layer opens.
public struct NoticeItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// The About screen's values. Name, version and copyright come from the bundle.
@Observable
public final class AboutModel {
    public var appName: String
    /// "0.0.1".
    public var version: String
    /// "1".
    public var build: String
    public var copyright: String?
    /// The speech model's licence and attribution, first.
    public var modelNotice: NoticeItem
    /// Everyone else's work the app includes.
    public var thirdPartyNotices: [NoticeItem]
    /// Opens a notice's full text.
    public var showNotice: (String) -> Void

    public init(appName: String, version: String, build: String, copyright: String?, modelNotice: NoticeItem,
                thirdPartyNotices: [NoticeItem], showNotice: @escaping (String) -> Void = { _ in }) {
        self.appName = appName
        self.version = version
        self.build = build
        self.copyright = copyright
        self.modelNotice = modelNotice
        self.thirdPartyNotices = thirdPartyNotices
        self.showNotice = showNotice
    }
}

/// About: the name and version, the promise that nothing leaves the Mac, the model's notice and everyone else's.
public struct AboutScreen: View {
    private let model: AboutModel

    public init(model: AboutModel) {
        self.model = model
    }

    public var body: some View {
        ScreenPage(String(localized: "About")) {
            VStack(alignment: .leading, spacing: 6) {
                IslandEmblem()
                    .padding(.bottom, 12)
                Text(model.appName)
                    .font(.display(40))
                    .foregroundStyle(Theme.ink)
                Text("Version \(model.version) (\(model.build))")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
                    .textSelection(.enabled)
            }
            .padding(Metrics.rowInset + 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .accessibilityElement(children: .combine)

            CardGroup(String(localized: "Privacy")) {
                Card {
                    SettingRow(String(localized: "\(model.appName) makes no network connections."),
                               detail: String(localized: "Speech is recognised on this Mac. The Run Log, the dictionary and your settings never leave it."),
                               symbol: "network.slash", symbolTint: Theme.ink)
                }
            }
            CardGroup(String(localized: "Speech model")) {
                Card { NoticeRow(notice: model.modelNotice, show: model.showNotice) }
            }
            CardGroup(String(localized: "Acknowledgements")) {
                Card {
                    ForEach(model.thirdPartyNotices) { notice in
                        NoticeRow(notice: notice, show: model.showNotice)
                    }
                }
            } footer: {
                if let copyright = model.copyright { Text(verbatim: copyright) }
            }
        }
    }
}

private struct NoticeRow: View {
    let notice: NoticeItem
    let show: (String) -> Void

    var body: some View {
        SettingRow(notice.title, detail: notice.detail) {
            Button(String(localized: "View")) { show(notice.id) }
                .buttonStyle(PrimaryButtonStyle(size: .compact))
                .accessibilityLabel(String(localized: "View \(notice.title)"))
        }
    }
}
