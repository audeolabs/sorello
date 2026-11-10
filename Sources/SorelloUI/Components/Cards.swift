import SwiftUI

/// Rows in a card, with a hairline between each pair, inset to where the words start. The card colour sits on the
/// screen colour, as on the iPhone.
public struct Card<Content: View>: View {
    private let content: Content
    /// Where the hairlines start, from the card's leading edge.
    private let dividerInset: CGFloat

    /// A card of the rows `content` builds; hairlines start `dividerInset` from the leading edge.
    public init(dividerInset: CGFloat = Metrics.rowInset, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.dividerInset = dividerInset
    }

    public var body: some View {
        Group(subviews: content) { rows in
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    if row.id != rows.first?.id {
                        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, dividerInset)
                    }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// A group: its title above, then its card, then an optional footnote below in secondary ink.
public struct CardGroup<Content: View, Footer: View>: View {
    private let title: String?
    private let content: Content
    private let footer: Footer

    /// A group titled `title`, with `footer` under its card.
    public init(_ title: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.tight) {
            if let title {
                Text(title)
                    .font(.groupTitle)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.leading, Metrics.rowInset)
                    .accessibilityAddTraits(.isHeader)
            }
            content
            footer
                .font(.rowDetail)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Metrics.rowInset)
        }
    }
}

/// A group without a footnote.
public extension CardGroup where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

/// One row: an optional glyph, a title with an optional line under it, and an accessory on the trailing side. Rows
/// with and without a detail line keep the same minimum height, and the accessory centres on the title block.
public struct SettingRow<Accessory: View>: View {
    private let title: String
    private let detail: String?
    private let symbol: String?
    private let symbolTint: Color
    private let accessory: Accessory

    /// A row with `title`, an optional `detail` line and glyph, and `accessory` on the trailing side.
    public init(_ title: String, detail: String? = nil, symbol: String? = nil, symbolTint: Color = Theme.secondaryInk,
                @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.symbolTint = symbolTint
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Metrics.glyphGap) {
            if let symbol {
                RowGlyph(symbol, tint: symbolTint)
            }
            RowWords(title: title, detail: detail)
            Spacer(minLength: 12)
            accessory
        }
        .rowPadding()
    }
}

/// A row with nothing on its trailing side.
public extension SettingRow where Accessory == EmptyView {
    init(_ title: String, detail: String? = nil, symbol: String? = nil, symbolTint: Color = Theme.secondaryInk) {
        self.init(title, detail: detail, symbol: symbol, symbolTint: symbolTint) { EmptyView() }
    }
}

/// A switch row: a glyph, a title and its line, and Sorello's switch.
public struct ToggleRow: View {
    private let title: String
    private let detail: String?
    private let symbol: String?
    @Binding private var isOn: Bool

    /// A switch row bound to `isOn`.
    public init(_ title: String, detail: String? = nil, symbol: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        _isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Metrics.glyphGap) {
                if let symbol { RowGlyph(symbol) }
                RowWords(title: title, detail: detail)
            }
        }
        .toggleStyle(.sorello)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
        .rowPadding()
    }
}

/// A row's title and the line under it.
struct RowWords: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.rowTitle)
                .foregroundStyle(Theme.ink)
            if let detail {
                Text(detail)
                    .font(.rowDetail)
                    .foregroundStyle(Theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row's glyph: plain, centred in a fixed width so the words of every row line up. Decorative.
public struct RowGlyph: View {
    private let symbol: String
    private let tint: Color

    /// The SF Symbol `symbol` in `tint`.
    public init(_ symbol: String, tint: Color = Theme.secondaryInk) {
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: Metrics.glyphWidth)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A row's padding and minimum height inside a card.
    func rowPadding() -> some View {
        padding(.horizontal, Metrics.rowInset)
            .padding(.vertical, Metrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
    }
}

/// A screen of the main window: its title in the display face, a line under it, then its groups, in a column that
/// stops growing at a readable width and scrolls when it is taller than the window.
public struct ScreenPage<Content: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content
    private let trailing: Trailing

    /// A page titled `title`, with `trailing` beside the title (a count, a button) and `content` under it.
    public init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.trailing = trailing()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.groupGap) {
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .displayType(.screenTitle)
                            .foregroundStyle(Theme.ink)
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    trailing
                }
                .padding(.bottom, 2)
                content
            }
            .frame(maxWidth: Metrics.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.top, Metrics.titleBarClearance)
            .padding(.bottom, Metrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
    }
}

/// A page with nothing beside its title.
public extension ScreenPage where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}
