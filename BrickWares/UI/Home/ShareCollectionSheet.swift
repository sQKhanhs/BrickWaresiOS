import Photos
import SwiftUI

/// The "Share Collection" sheet — a port of Android's `ShareCollectionSheet`: a preview card (rendered to
/// an image on Save / Share) over a brick-texture background, with a light/dark preview toggle and a
/// hide-value toggle. Currency and language follow the app's settings.
///
/// "Top Sets/Minifigs" is three editable slots: tap one to pick an item from the collection. Empty slots
/// show a dashed "add" placeholder in the editor and are left out of the shared image, as are the eye
/// toggle and the slots' clear buttons.
struct ShareCollectionSheet: View {
    let items: [CollectionItem]
    let summary: CollectionSummary
    let themes: [ThemeSummary]
    let memberName: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings

    /// Nil until the user picks: the preview starts in the app's own appearance.
    @State private var darkChoice: Bool?
    /// The itemized values (top items + by theme).
    @State private var showValue = true
    /// The big collection value — its own toggle, the eye next to it.
    @State private var showCollectionValue = true
    /// The three chosen slots by variant key (nil = empty) — per variant, so two figures of one series
    /// can't collide on a slot.
    @State private var slots: [String?] = [nil, nil, nil]
    @State private var editingSlot: Int?
    /// Thumbnails of the chosen items, loaded up front: the image renderer can't wait for async images.
    @State private var thumbs: [String: UIImage] = [:]
    @State private var rendered: ShareImage?
    @State private var saving = false
    @State private var notice: String?

    private var dark: Bool { darkChoice ?? (colorScheme == .dark) }

    /// Every owned item, most valuable first — the pool the slots pick from.
    private var pool: [ShareEntry] {
        let currency = settings.currency
        return items.map { item in
            ShareEntry(
                id: item.variantKey, setNumber: item.setNumber, name: item.name, theme: item.theme,
                value: item.worthPerUnit(in: currency) * Int64(item.totalQty),
                imageUrls: (item.itemType == .minifig
                    ? [item.imageUrl]
                    : RowImages.card(imageUrl: item.imageUrl, boxImageUrl: item.boxImageUrl)).compactMap { $0?.nilIfBlank }
            )
        }
        .sorted { $0.value > $1.value }
    }

    /// Slots resolved against the live collection (an item no longer owned drops out).
    private func selected(in pool: [ShareEntry]) -> [ShareEntry?] {
        slots.map { key in key.flatMap { k in pool.first { $0.id == k } } }
    }

    private func card(captureMode: Bool, pool: [ShareEntry]) -> ShareCard {
        ShareCard(
            memberName: memberName, summary: summary,
            themes: Array(themes.sorted { $0.totalValue > $1.totalValue }.prefix(4)),
            currency: settings.currency, dark: dark, showValue: showValue, showCollectionValue: showCollectionValue,
            captureMode: captureMode, selected: selected(in: pool), thumbs: thumbs,
            onEditSlot: { editingSlot = $0 }, onClearSlot: { slots[$0] = nil },
            onToggleCollectionValue: { showCollectionValue.toggle() }
        )
    }

    var body: some View {
        let pool = pool
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    card(captureMode: false, pool: pool)
                        .frame(width: ShareCard.width)
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)

                    VStack(spacing: 10) {
                        previewThemeToggle
                        Button { showValue.toggle() } label: {
                            Label(L(showValue ? "share_hide_value" : "share_show_value"), systemImage: showValue ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.bwSecondaryCompact)

                        HStack(spacing: 10) {
                            Button { Task { await save() } } label: {
                                Label(L("share_save"), systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bwSecondary)
                            .disabled(rendered == nil || saving)

                            if let rendered {
                                ShareLink(item: rendered, preview: SharePreview(L("share_chooser_title"), image: rendered.image)) {
                                    Label(L("share_action"), systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bwPrimary)
                            } else {
                                Button {} label: { Label(L("share_action"), systemImage: "square.and.arrow.up") }
                                    .buttonStyle(.bwPrimary)
                                    .disabled(true)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(Bw.gutter)
            }
            .bwScreen()
            .navigationTitle(L("share_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } }
            }
            .navigationDestination(isPresented: Binding(get: { editingSlot != nil }, set: { if !$0 { editingSlot = nil } })) {
                if let slot = editingSlot {
                    SharePicker(
                        entries: pool, currency: settings.currency,
                        // Already in another slot: greyed out, so the card never shows an item twice.
                        taken: Set(slots.enumerated().filter { $0.offset != slot }.compactMap { $0.element })
                    ) { key in
                        slots[slot] = key
                        editingSlot = nil
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.subheadline.weight(.medium)).foregroundStyle(Bw.bg)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Bw.text.opacity(0.92), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: notice)
        }
        .task(id: slots) { await loadThumbs(pool) }
        .task(id: RenderKey(
            dark: dark, value: showValue, hero: showCollectionValue, slots: slots, thumbs: thumbs.keys.sorted(),
            currency: settings.currency, summary: summary, themes: themes
        )) { render(pool) }
    }

    /// Light / Dark for the CARD only (not the app).
    private var previewThemeToggle: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { isDark in
                let on = dark == isDark
                Button { darkChoice = isDark } label: {
                    Text(L(isDark ? "theme_dark" : "theme_light"))
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(on ? Bw.bg : Bw.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(on ? Bw.text : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Bw.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Bw.border))
    }

    private struct RenderKey: Hashable {
        var dark, value, hero: Bool
        var slots: [String?]
        var thumbs: [String]
        var currency: AppCurrency
        var summary: CollectionSummary
        var themes: [ThemeSummary]
    }

    /// The image that Save / Share hand out: the card without its editor controls and empty slots.
    @MainActor private func render(_ pool: [ShareEntry]) {
        let renderer = ImageRenderer(content: card(captureMode: true, pool: pool).frame(width: ShareCard.width))
        renderer.scale = max(displayScale, 3)
        rendered = renderer.uiImage.map(ShareImage.init)
    }

    private func loadThumbs(_ pool: [ShareEntry]) async {
        for entry in selected(in: pool).compactMap({ $0 }) where thumbs[entry.id] == nil {
            for url in entry.imageUrls {
                if let image = await ImageLoader.shared.image(url, maxPixel: ShareCard.thumbSize * 3) {
                    thumbs[entry.id] = image
                    break
                }
            }
        }
    }

    private func save() async {
        guard let image = rendered?.uiImage else { return show(L("share_failed")) }
        saving = true
        defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return show(L("share_save_failed")) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            show(L("share_saved"))
        } catch {
            show(L("share_save_failed"))
        }
    }

    /// The app's toast lives under this sheet, so the sheet shows its own.
    private func show(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if notice == text { notice = nil }
        }
    }
}

/// A collection item as a "Top Sets" slot / picker row. `value` is the line's total worth in the display
/// currency.
struct ShareEntry: Identifiable, Hashable {
    var id: String
    var setNumber: String
    var name: String
    var theme: String
    var value: Int64
    var imageUrls: [String]
}

struct ShareImage: Transferable {
    let uiImage: UIImage
    var image: Image { Image(uiImage: uiImage) }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.uiImage.pngData() ?? Data() }
            .suggestedFileName("brickwares-collection.png")
    }
}

// MARK: - The card

/// The card itself. Fixed colours and font sizes (not the dynamic tokens or Dynamic Type): it is
/// rasterized, and its light/dark look belongs to the card, not to the device appearance. In
/// `captureMode` everything that only makes sense in the editor is left out. (Internal, not private, so
/// the render test can build one.)
struct ShareCard: View {
    static let width: CGFloat = 300
    static let thumbSize: CGFloat = 44

    let memberName: String?
    let summary: CollectionSummary
    let themes: [ThemeSummary]
    let currency: AppCurrency
    let dark: Bool
    let showValue: Bool
    let showCollectionValue: Bool
    let captureMode: Bool
    let selected: [ShareEntry?]
    let thumbs: [String: UIImage]
    var onEditSlot: (Int) -> Void = { _ in }
    var onClearSlot: (Int) -> Void = { _ in }
    var onToggleCollectionValue: () -> Void = {}

    // Android `shareCardColors`.
    private var ink: Color { dark ? .white : Color(hex: 0x1A1A1A) }
    private var muted: Color { ink.opacity(0.55) }
    private var border: Color { ink.opacity(dark ? 0.15 : 0.12) }
    private var surface: Color { .white.opacity(dark ? 0.08 : 0.65) }
    private var track: Color { ink.opacity(dark ? 0.15 : 0.12) }
    private var overlay: Color { dark ? Color(hex: 0x18181B).opacity(0.82) : Color(hex: 0xFAF8F5).opacity(0.85) }
    private let accent = Color(hex: 0xC99A1E)
    private let yellow = Color(hex: 0xFFD500)
    private let hidden = "••••"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hairline
            collectionValue
            HStack(spacing: 8) {
                stat(Money.count(summary.setCount), L("stat_sets"))
                stat(Money.count(summary.pieceCount), L("stat_pieces"))
                stat(Money.count(summary.minifigCount), L("stat_minifigs"))
            }
            // Empty slots are an invitation in the editor and nothing in the image.
            if !captureMode || selected.contains(where: { $0 != nil }) { topItems }
            if !themes.isEmpty { byTheme }
            hairline
            Text(L("share_footer"))
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(muted)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18).padding(.vertical, 20)
        // The texture goes BEHIND the content so its fill size never drives the card's layout.
        .background {
            ZStack {
                Image(dark ? "share_preview_dark" : "share_preview_light").resizable().scaledToFill()
                overlay
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(border))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                if let memberName, !memberName.isEmpty {
                    Text(memberName).font(.system(size: 13, weight: .bold)).foregroundStyle(ink).lineLimit(1)
                }
                Text(L("collection_title")).font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
            }
            Spacer(minLength: 0)
            (Text(verbatim: "Brick").foregroundStyle(ink) + Text(verbatim: "Wares").foregroundStyle(yellow))
                .font(.system(size: 12, weight: .black))
        }
    }

    private var hairline: some View { Rectangle().fill(border).frame(height: 1) }

    private var collectionValue: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("home_collection_value").uppercased())
                .font(.system(size: 10, weight: .heavy)).tracking(0.4).foregroundStyle(accent)
            HStack(spacing: 8) {
                Text(showCollectionValue ? Money.formatIn(summary.collectionValue, currency) : hidden)
                    .font(.system(size: 32, weight: .black)).foregroundStyle(ink)
                    .minimumScaleFactor(0.5).lineLimit(1)
                // A reveal toggle, like a password field's — editor only.
                if !captureMode {
                    Button(action: onToggleCollectionValue) {
                        Image(systemName: showCollectionValue ? "eye" : "eye.slash")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(muted)
                            .frame(width: 28, height: 28)
                            .background(surface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(showCollectionValue ? "share_hide_value" : "share_show_value"))
                }
            }
        }
    }

    private var topItems: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L("share_top_sets"))
            ForEach(Array(selected.enumerated()), id: \.offset) { index, entry in
                if let entry {
                    filledSlot(entry, index: index)
                } else if !captureMode {
                    placeholderSlot(index)
                }
            }
        }
    }

    @ViewBuilder private func filledSlot(_ entry: ShareEntry, index: Int) -> some View {
        let row = HStack(spacing: 10) {
            thumb(entry)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12, weight: .bold)).foregroundStyle(ink).lineLimit(1)
                Text(entry.theme).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(showValue ? Money.formatIn(entry.value, currency) : hidden)
                .font(.system(size: 12, weight: .heavy)).foregroundStyle(accent).lineLimit(1)
        }
        if captureMode {
            // Plain content in the image: a disabled button would render its label dimmed.
            row
        } else {
            HStack(spacing: 10) {
                // Tap the item to change it.
                Button { onEditSlot(index) } label: { row.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                Button { onClearSlot(index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(muted)
                        .frame(width: 22, height: 22)
                        .background(surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("action_remove"))
            }
        }
    }

    private func thumb(_ entry: ShareEntry) -> some View {
        ZStack {
            if let image = thumbs[entry.id] {
                Image(uiImage: image).resizable().scaledToFit().padding(4)
            } else {
                Text(entry.setNumber).font(.system(size: 8, design: .monospaced)).foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.6).padding(3)
            }
        }
        .frame(width: Self.thumbSize, height: Self.thumbSize)
        .background(surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func placeholderSlot(_ index: Int) -> some View {
        Button { onEditSlot(index) } label: {
            HStack(spacing: 8) {
                Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
                Text(L("share_add_set_slot")).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(muted)
            .padding(.horizontal, 12).padding(.vertical, 13)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(muted, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var byTheme: some View {
        let maxValue = max(themes.map(\.totalValue).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 7) {
            sectionLabel(L("share_by_theme"))
            ForEach(themes) { theme in
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text(theme.theme.isEmpty ? "—" : theme.theme)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                        Spacer(minLength: 0)
                        // "Items", not "sets": a theme's count includes standalone minifigs.
                        (Text(verbatim: L(theme.setCount == 1 ? "home_theme_item_one" : "home_theme_item_other", theme.setCount) + " · ")
                            .foregroundStyle(muted)
                            + Text(showValue ? Money.formatIn(theme.totalValue, currency) : hidden).fontWeight(.bold).foregroundStyle(accent))
                            .font(.system(size: 11)).lineLimit(1)
                    }
                    Capsule().fill(track).frame(height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule().fill(yellow)
                                    .frame(width: geo.size.width * min(max(Double(theme.totalValue) / Double(maxValue), 0), 1))
                            }
                        }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .heavy)).tracking(0.3).foregroundStyle(muted)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .heavy)).foregroundStyle(ink).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 6).padding(.vertical, 9)
        .background(surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Picker

/// "Choose a set": every owned item, most valuable first.
private struct SharePicker: View {
    let entries: [ShareEntry]
    let currency: AppCurrency
    let taken: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        List(entries) { entry in
            let isTaken = taken.contains(entry.id)
            Button { onPick(entry.id) } label: {
                HStack(spacing: 12) {
                    ItemThumb(urls: entry.imageUrls, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.subheadline.weight(.bold)).foregroundStyle(Bw.text).lineLimit(1)
                        Text(entry.theme).font(.caption).foregroundStyle(Bw.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(Money.formatIn(entry.value, currency)).font(.footnote.weight(.bold)).foregroundStyle(Bw.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTaken)
            .opacity(isTaken ? 0.4 : 1)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .bwScreen()
        .navigationTitle(L("share_choose_set"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
