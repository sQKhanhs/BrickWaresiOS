import Observation
import SwiftUI

/// Which set numbers / fig numbers the user owns, wishlists, or has sold — maintained by `RootView`
/// from the live rows so any card can render its state-aware actions without its own queries.
@MainActor
@Observable
final class OwnershipIndex {
    /// `ItemKey` variant keys of the user's active rows — so owning one figure of a CMF series doesn't
    /// mark its siblings as owned.
    private(set) var owned: Set<String> = []
    private(set) var wishlisted: Set<String> = []
    private(set) var sold: Set<String> = []

    func update(owned: Set<String>, wishlisted: Set<String>, sold: Set<String>) {
        if self.owned != owned { self.owned = owned }
        if self.wishlisted != wishlisted { self.wishlisted = wishlisted }
        if self.sold != sold { self.sold = sold }
    }

    // A catalog item matches on its exact variant, or on the bare number a legacy row carries.
    func isOwned(_ item: CatalogSet) -> Bool { item.ownershipKeys.contains(where: owned.contains) }
    func isWishlisted(_ item: CatalogSet) -> Bool { item.ownershipKeys.contains(where: wishlisted.contains) }
    func isOwnedOrSold(_ item: CatalogSet) -> Bool { isOwned(item) || item.ownershipKeys.contains(where: sold.contains) }
}

/// Per-screen presenter for the shared item sheets, so lazily-recycled cards never own a sheet.
/// Install with `.itemSheets()`; cards reach it through the environment.
@MainActor
@Observable
final class ItemSheetCoordinator {
    var addRequest: AddSheetRequest?
    var detailsRequest: ItemDetailsRequest?
    var gallery: GalleryRequest?

    /// Add / wishlist are write features: signed-out taps raise the login sheet instead.
    func add(_ item: CatalogSet, salesMode: Bool = false, allowSalesMode: Bool = true, auth: AuthService) {
        guard auth.isSignedIn else { auth.requestSignIn(); return }
        addRequest = .add(item, salesMode: salesMode, allowSalesMode: allowSalesMode)
    }

    func details(_ item: CatalogSet, tab: ItemDetailsRequest.Tab = .collection) {
        detailsRequest = ItemDetailsRequest(item: item, initialTab: tab)
    }

    /// `start` opens the gallery at that image (the one the hero was showing) instead of the first.
    func showGallery(_ urls: [String], startingAt start: String? = nil) {
        guard !urls.isEmpty else { return }
        gallery = GalleryRequest(urls: urls, start: start)
    }
}

private struct ItemSheetsModifier: ViewModifier {
    @State private var coordinator = ItemSheetCoordinator()
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .environment(coordinator)
            .sheet(item: $coordinator.addRequest) { request in
                AddToCollectionSheet(request: request) { item, toSales in
                    router.showToast(L(toSales ? "toast_added_sales" : "toast_added_collection", item.name))
                }
            }
            .sheet(item: $coordinator.detailsRequest) { ItemDetailsSheet(request: $0) }
            .fullScreenCover(item: $coordinator.gallery) { ImageGallery(urls: $0.urls, start: $0.start) }
    }
}

extension View {
    /// Hosts the Add sheet, the See-Details sheet and the image gallery for every card below.
    func itemSheets() -> some View { modifier(ItemSheetsModifier()) }
}

// MARK: - Catalog set card (search results, theme lists, recommendations, new sets)

/// A catalog set in a list (search results, a theme's sets, New Sets, "More in …") — Android's
/// `SetResultCard`. It ALWAYS shows Retail and the community Value ("----" until one exists), whatever
/// the set's status, with the "!" explainer beside the status badge; then Add + Wishlist, or a single
/// See Detail once the set is owned.
struct SetResultCard: View {
    let set: CatalogSet

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(CollectionService.self) private var collection
    @Environment(ValueService.self) private var values
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var isOwned: Bool { ownership.isOwnedOrSold(set) }
    private var isWishlisted: Bool { ownership.isWishlisted(set) }

    var body: some View {
        let _ = (settings.ratesRevision, values.revision)
        let value = values.value(forSet: set.setId)
        HStack(alignment: .top, spacing: 10) {
            Button { sheets.showGallery(set.galleryUrls) } label: { ItemThumb(urls: set.cardImageUrls, size: 72) }
                .buttonStyle(.plain)
                .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 5) {
                Button { router.open(.set(set.id)) } label: {
                    Text(verbatim: "\(set.setNumber) \(set.name)")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Bw.link)
                        .multilineTextAlignment(.leading).cardTitleLines()
                }
                .buttonStyle(.plain)

                MetaLine(L("meta_theme"), set.theme)
                MetaLine(L("meta_release"), releaseLabel(year: set.releaseYear, month: set.releaseMonth))
                MetaLine(L("meta_pieces_minifigs"), "\(Money.count(set.pieces)) / \(set.minifigs)")
                StatusBadgeWithValueInfo(status: set.status, value: value)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                PriceLine(
                    label: L("price_retail"),
                    value: set.retailPrice.map { Money.format(usdCents: $0, in: settings.currency) } ?? L("price_no_retail")
                )
                ValueLine(label: L("price_value"), value: value, spread: true, showsInfo: false)
                if isOwned {
                    Button { sheets.details(set, tab: ownership.isOwned(set) ? .collection : .sales) } label: {
                        Label(L("action_see_detail"), systemImage: "checkmark")
                    }
                    .buttonStyle(.bwTonalColumn)
                    .padding(.top, 2)
                } else {
                    Button { sheets.add(set, auth: auth) } label: { CardAddLabel() }
                        .buttonStyle(.bwPrimaryColumn)
                        .padding(.top, 2)
                    WishlistButton(item: set, isWishlisted: isWishlisted, size: .column)
                }
            }
            .priceColumn()
        }
        .bwCard()
    }
}

/// "Add" with the brick icon, as on Android's cards.
struct CardAddLabel: View {
    var body: some View {
        Label { Text(L("action_add")) } icon: {
            Image("ic_bw_pieces").resizable().scaledToFit().frame(width: 14, height: 14)
        }
    }
}

/// "Wishlist" / "Wishlisted": the heart turns pink when the item is wanted; the title stays text-coloured.
struct CardWishlistLabel: View {
    let isWishlisted: Bool

    var body: some View {
        Label { Text(L(isWishlisted ? "action_wishlisted" : "action_wishlist")) } icon: {
            Image(systemName: isWishlisted ? "heart.fill" : "heart")
                .foregroundStyle(isWishlisted ? Color(hex: 0xC9506F) : Bw.textMuted)
        }
    }
}

/// Wishlist / Wishlisted toggle (gated behind sign-in).
struct WishlistButton: View {
    let item: CatalogSet
    let isWishlisted: Bool
    var size: BwButtonSize = .compact

    @Environment(AuthService.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CollectionService.self) private var collection

    var body: some View {
        Button {
            guard auth.isSignedIn else { auth.requestSignIn(); return }
            collection.toggleWishlist(item, isWishlisted: isWishlisted)
            router.showToast(L(isWishlisted ? "toast_removed_wishlist" : "toast_added_wishlist", item.name))
        } label: {
            CardWishlistLabel(isWishlisted: isWishlisted)
        }
        .buttonStyle(BwSecondaryButtonStyle(size: size))
        .sensoryFeedback(.selection, trigger: isWishlisted)
    }
}

/// "Label value" meta line, flowing like Android's (a `FlowRow`): label and value share a line when they
/// fit; when they don't, the value drops to the next line WHOLE and may then wrap to two lines there —
/// instead of being squeezed into a narrow column beside the label ("Pieces /" over "Minifigs", or a
/// theme broken across a hanging indent).
struct MetaLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    private var labelText: some View {
        Text(label).font(.caption2).foregroundStyle(Bw.textMuted).lineLimit(1)
    }

    private var valueText: some View {
        Text(value.isEmpty ? "—" : value).font(.caption2.weight(.semibold)).foregroundStyle(Bw.textSecondary)
            .multilineTextAlignment(.leading)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                labelText
                valueText.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                labelText
                valueText.lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Catalog minifig card

/// A catalog minifig in a list — Android's search `MinifigCard`: number, name and "In N sets" (with the
/// value "!" beside it) on the left; the community Value — always, a minifig has no retail — and the
/// actions on the right. An owned fig gets See Detail (Android shows a plain "Owned" tag there).
struct MinifigCard: View {
    let fig: Minifig

    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(ValueService.self) private var values
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var asSet: CatalogSet { .fromMinifig(fig) }

    var body: some View {
        let _ = values.revision
        let value = values.value(forFig: fig.figNum)
        HStack(alignment: .top, spacing: 10) {
            Button { sheets.showGallery([fig.imageUrl].compactMap { $0 }) } label: { ItemThumb(urls: [fig.imageUrl], size: 64) }
                .buttonStyle(.plain)
                .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(fig.figNum).font(.caption2).foregroundStyle(Bw.textMuted)
                Button { router.open(.minifig(fig.figNum)) } label: {
                    Text(fig.name).font(.subheadline.weight(.bold)).foregroundStyle(Bw.link)
                        .multilineTextAlignment(.leading).cardTitleLines()
                }
                .buttonStyle(.plain)
                if fig.setCount > 0 { MinifigSetsWithValueInfo(setCount: fig.setCount, value: value) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                // The "!" sits beside "In N sets" when that line shows; else it stays here.
                ValueLine(label: L("price_value"), value: value, spread: true, showsInfo: fig.setCount == 0)
                if ownership.isOwnedOrSold(asSet) {
                    Button { sheets.details(asSet, tab: ownership.isOwned(asSet) ? .collection : .sales) } label: {
                        Label(L("action_see_detail"), systemImage: "checkmark")
                    }
                    .buttonStyle(.bwTonalColumn)
                    .padding(.top, 2)
                } else {
                    Button { sheets.add(asSet, auth: auth) } label: { CardAddLabel() }
                        .buttonStyle(.bwPrimaryColumn)
                        .padding(.top, 2)
                    WishlistButton(item: asSet, isWishlisted: ownership.isWishlisted(asSet), size: .column)
                }
            }
            .priceColumn(minWidth: 118)
        }
        .bwCard()
    }
}
