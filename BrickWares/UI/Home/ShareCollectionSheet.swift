import SwiftUI

/// Builds a shareable collection card and hands it to the native share sheet (which also offers
/// "Save Image"). Options mirror Android: light/dark card, hide the hero value, hide itemized values.
struct ShareCollectionSheet: View {
    let items: [CollectionItem]
    let summary: CollectionSummary
    let themes: [ThemeSummary]
    let memberName: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(AppSettings.self) private var settings

    @State private var dark = false
    @State private var hideHeroValue = false
    @State private var hideItemValues = false
    @State private var rendered: ShareImage?

    private var topItems: [CollectionItem] {
        items.sorted {
            $0.worthPerUnit(in: settings.currency) * Int64($0.totalQty) > $1.worthPerUnit(in: settings.currency) * Int64($1.totalQty)
        }.prefix(3).map { $0 }
    }

    private var card: ShareCard {
        ShareCard(
            memberName: memberName, summary: summary, topItems: topItems, themes: Array(themes.prefix(4)),
            currency: settings.currency, dark: dark, hideHeroValue: hideHeroValue, hideItemValues: hideItemValues
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    card
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

                    VStack(spacing: 0) {
                        Picker(L("settings_theme"), selection: $dark) {
                            Text(L("theme_light")).tag(false)
                            Text(L("theme_dark")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 12)
                        Toggle(L("share_hide_value"), isOn: $hideItemValues)
                        Divider().padding(.vertical, 8)
                        Toggle(L("home_collection_value"), isOn: Binding(get: { !hideHeroValue }, set: { hideHeroValue = !$0 }))
                    }
                    .bwCard(padding: 16)
                }
                .padding(Bw.gutter)
            }
            .bwScreen()
            .navigationTitle(L("share_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let rendered {
                        ShareLink(item: rendered, preview: SharePreview(L("share_chooser_title"), image: rendered.image)) {
                            Text(L("share_action")).fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .task(id: RenderKey(dark: dark, hero: hideHeroValue, items: hideItemValues)) { render() }
    }

    private struct RenderKey: Hashable { var dark, hero, items: Bool }

    @MainActor private func render() {
        let renderer = ImageRenderer(content: card.frame(width: 340))
        renderer.scale = max(displayScale, 3)
        rendered = renderer.uiImage.map(ShareImage.init)
    }
}

struct ShareImage: Transferable {
    let uiImage: UIImage
    var image: Image { Image(uiImage: uiImage) }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.uiImage.pngData() ?? Data() }
            .suggestedFileName("brickwares-collection.png")
    }
}

/// The card itself. Uses fixed colors (not the dynamic tokens) because it is rasterized and the
/// light/dark choice belongs to the card, not to the device appearance.
private struct ShareCard: View {
    let memberName: String?
    let summary: CollectionSummary
    let topItems: [CollectionItem]
    let themes: [ThemeSummary]
    let currency: AppCurrency
    let dark: Bool
    let hideHeroValue: Bool
    let hideItemValues: Bool

    private var bg: Color { dark ? Color(hex: 0x18181B) : Color(hex: 0xFAF8F5) }
    private var ink: Color { dark ? Color(hex: 0xF3F1EA) : Color(hex: 0x1A1A1A) }
    private var muted: Color { dark ? Color(hex: 0xA9A79D) : Color(hex: 0x8A8A84) }
    private var tile: Color { dark ? Color(hex: 0x2B2B27) : .white }
    private var accent: Color { Color(hex: 0xC99A1E) }
    private let masked = "••••"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    if let memberName, !memberName.isEmpty {
                        Text(memberName).font(.caption.weight(.semibold)).foregroundStyle(muted)
                    }
                    Text(L("collection_title")).font(.headline).foregroundStyle(ink)
                }
                Spacer()
                (Text(verbatim: "Brick").foregroundStyle(ink) + Text(verbatim: "Wares").foregroundStyle(Color(hex: 0xFFD500)))
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
            }
            Rectangle().fill(muted.opacity(0.25)).frame(height: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("home_collection_value").uppercased()).font(.caption2.weight(.heavy)).tracking(0.8).foregroundStyle(accent)
                Text(hideHeroValue ? masked : Money.formatIn(summary.collectionValue, currency))
                    .font(.system(size: 32, weight: .heavy, design: .rounded)).foregroundStyle(ink)
                    .minimumScaleFactor(0.5).lineLimit(1)
            }

            HStack(spacing: 8) {
                stat(Money.count(summary.setCount), L("stat_sets"))
                stat(Money.count(summary.pieceCount), L("stat_pieces"))
                stat(Money.count(summary.minifigCount), L("stat_minifigs"))
            }

            if !topItems.isEmpty {
                Text(L("share_top_sets")).font(.caption.weight(.bold)).foregroundStyle(muted)
                ForEach(topItems) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.footnote.weight(.semibold)).foregroundStyle(ink).lineLimit(1)
                            Text(item.theme).font(.caption2).foregroundStyle(muted).lineLimit(1)
                        }
                        Spacer()
                        Text(hideItemValues ? masked : Money.formatIn(item.worthPerUnit(in: currency) * Int64(item.totalQty), currency))
                            .font(.footnote.weight(.bold)).foregroundStyle(ink)
                    }
                }
            }

            if !themes.isEmpty {
                Text(L("share_by_theme")).font(.caption.weight(.bold)).foregroundStyle(muted)
                let maxValue = max(themes.map(\.totalValue).max() ?? 1, 1)
                ForEach(themes) { theme in
                    VStack(spacing: 4) {
                        HStack {
                            Text(theme.theme).font(.caption.weight(.semibold)).foregroundStyle(ink).lineLimit(1)
                            Spacer()
                            Text(hideItemValues ? masked : Money.formatIn(theme.totalValue, currency)).font(.caption2).foregroundStyle(muted)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(muted.opacity(0.22))
                                Capsule().fill(Color(hex: 0xFFD500))
                                    .frame(width: geo.size.width * min(max(Double(theme.totalValue) / Double(maxValue), 0), 1))
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }

            Rectangle().fill(muted.opacity(0.25)).frame(height: 1)
            Text(L("share_footer")).font(.caption2.weight(.semibold)).foregroundStyle(muted).frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(bg)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(ink).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 9)
        .background(tile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
