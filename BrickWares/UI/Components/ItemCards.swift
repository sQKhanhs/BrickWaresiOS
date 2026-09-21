import Observation
import SwiftUI

/// Which set numbers / fig numbers the user owns, wishlists, or has sold — maintained by `RootView`
/// from the live rows so any card can render its state-aware actions without its own queries.
@MainActor
@Observable
final class OwnershipIndex {
    private(set) var owned: Set<String> = []
    private(set) var wishlisted: Set<String> = []
    private(set) var sold: Set<String> = []

    func update(owned: Set<String>, wishlisted: Set<String>, sold: Set<String>) {
        if self.owned != owned { self.owned = owned }
        if self.wishlisted != wishlisted { self.wishlisted = wishlisted }
        if self.sold != sold { self.sold = sold }
    }

    func isOwnedOrSold(_ number: String) -> Bool { owned.contains(number) || sold.contains(number) }
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

    func showGallery(_ urls: [String]) {
        guard !urls.isEmpty else { return }
        gallery = GalleryRequest(urls: urls)
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
            .fullScreenCover(item: $coordinator.gallery) { ImageGallery(urls: $0.urls) }
    }
}

extension View {
    /// Hosts the Add sheet, the See-Details sheet and the image gallery for every card below.
    func itemSheets() -> some View { modifier(ItemSheetsModifier()) }
}

// MARK: - Catalog set card (search results, theme lists, recommendations, new sets)

struct SetResultCard: View {
    let set: CatalogSet

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(CollectionService.self) private var collection
    @Environment(ValueService.self) private var values
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var isOwned: Bool { ownership.isOwnedOrSold(set.setNumber) }
    private var isWishlisted: Bool { ownership.wishlisted.contains(set.setNumber) }

    var body: some View {
        let _ = settings.ratesRevision
        HStack(alignment: .top, spacing: 12) {
            Button { sheets.showGallery(set.galleryUrls) } label: { ItemThumb(urls: set.cardImageUrls, size: 84) }
                .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Button { router.open(.set(set.id)) } label: {
                    Text(verbatim: "\(set.setNumber) \(set.name)")
                        .font(.subheadline.weight(.bold)).foregroundStyle(Bw.link)
                        .multilineTextAlignment(.leading).lineLimit(2)
                }
                .buttonStyle(.plain)

                MetaLine(L("meta_theme"), set.theme)
                MetaLine(L("meta_release"), releaseLabel(year: set.releaseYear, month: set.releaseMonth))
                MetaLine(L("meta_pieces_minifigs"), "\(Money.count(set.pieces)) / \(set.minifigs)")
                StatusBadge(status: set.status)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    PriceLine(
                        label: L("price_retail"),
                        value: set.retailPrice.map { Money.format(usdCents: $0, in: settings.currency) } ?? L("price_no_retail"),
                        bold: true
                    )
                    if set.status.showsCommunityValue {
                        ValueLine(label: L("price_value"), value: values.value(forSet: set.setId))
                    }
                }
                .padding(.top, 1)

                actions.padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bwCard()
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if isOwned {
                Button { sheets.details(set, tab: ownership.owned.contains(set.setNumber) ? .collection : .sales) } label: {
                    Label(L("action_see_detail"), systemImage: "checkmark")
                }
                .buttonStyle(.bwSecondaryCompact)
            } else {
                Button { sheets.add(set, auth: auth) } label: { Label(L("action_add"), systemImage: "plus") }
                    .buttonStyle(.bwPrimaryCompact)
                WishlistButton(item: set, isWishlisted: isWishlisted)
            }
        }
    }
}

/// Wishlist / Wishlisted toggle (gated behind sign-in).
struct WishlistButton: View {
    let item: CatalogSet
    let isWishlisted: Bool

    @Environment(AuthService.self) private var auth
    @Environment(AppRouter.self) private var router
    @Environment(CollectionService.self) private var collection

    var body: some View {
        Button {
            guard auth.isSignedIn else { auth.requestSignIn(); return }
            collection.toggleWishlist(item, isWishlisted: isWishlisted)
            router.showToast(L(isWishlisted ? "toast_removed_wishlist" : "toast_added_wishlist", item.name))
        } label: {
            Label(L(isWishlisted ? "action_wishlisted" : "action_wishlist"), systemImage: isWishlisted ? "heart.fill" : "heart")
        }
        .buttonStyle(BwSecondaryButtonStyle(compact: true, tint: isWishlisted ? Color(hex: 0xC9506F) : Bw.text))
        .sensoryFeedback(.selection, trigger: isWishlisted)
    }
}

/// "Label value" meta line; the value stays on one line.
struct MetaLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label).font(.caption2).foregroundStyle(Bw.textMuted)
            Text(value.isEmpty ? "—" : value).font(.caption2.weight(.semibold)).foregroundStyle(Bw.textSecondary).lineLimit(1)
        }
    }
}

// MARK: - Catalog minifig card

struct MinifigCard: View {
    let fig: Minifig

    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(ValueService.self) private var values
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var asSet: CatalogSet { .fromMinifig(fig) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { sheets.showGallery([fig.imageUrl].compactMap { $0 }) } label: { ItemThumb(urls: [fig.imageUrl], size: 84) }
                .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text(fig.figNum).font(.caption2).foregroundStyle(Bw.textMuted)
                Button { router.open(.minifig(fig.figNum)) } label: {
                    Text(fig.name).font(.subheadline.weight(.bold)).foregroundStyle(Bw.link)
                        .multilineTextAlignment(.leading).lineLimit(2)
                }
                .buttonStyle(.plain)
                if !fig.themes.isEmpty { MetaLine(L("meta_theme"), fig.themes.prefix(2).joined(separator: ", ")) }
                MetaLine(L("minifig_in_sets_label"), String(fig.setCount))
                ValueLine(label: L("price_value"), value: values.value(forFig: fig.figNum))

                HStack(spacing: 8) {
                    if ownership.isOwnedOrSold(fig.figNum) {
                        Button { sheets.details(asSet, tab: ownership.owned.contains(fig.figNum) ? .collection : .sales) } label: {
                            Label(L("action_see_detail"), systemImage: "checkmark")
                        }
                        .buttonStyle(.bwSecondaryCompact)
                    } else {
                        Button { sheets.add(asSet, auth: auth) } label: { Label(L("action_add"), systemImage: "plus") }
                            .buttonStyle(.bwPrimaryCompact)
                        WishlistButton(item: asSet, isWishlisted: ownership.wishlisted.contains(fig.figNum))
                    }
                }
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .bwCard()
    }
}
