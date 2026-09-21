import SwiftData
import SwiftUI

struct MinifigDetailView: View {
    let figNum: String

    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(Connectivity.self) private var connectivity
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(ValueService.self) private var values

    @Query private var copyRows: [CollectionCopy]

    @State private var fig: Minifig?
    @State private var appearsIn: [CatalogSet] = []
    @State private var phase: LoadPhase = .loading
    @State private var currentValue: CurrentValue?
    @State private var valueLoading = true

    init(figNum: String) {
        self.figNum = figNum
        _copyRows = Query(filter: #Predicate<CollectionCopy> { $0.setNumber == figNum && !$0.tombstoned })
    }

    /// A minifig is "Retail" while ANY set containing it is still obtainable, else "Retired".
    /// nil = unknown (its sets haven't loaded / it appears in none).
    private var retired: Bool? {
        guard !appearsIn.isEmpty else { return nil }
        let obtainable: Set<Availability> = [.available, .exclusive, .pending, .gwp]
        return !appearsIn.contains { obtainable.contains($0.status) }
    }

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                ProgressView().tint(Bw.yellow).frame(maxWidth: .infinity).padding(.top, 100)
            case .failed:
                ErrorStateView(message: connectivity.isOnline ? L("error_connection") : L("detail_no_internet")) { Task { await load() } }
            case .loaded:
                if let fig {
                    MinifigContent(fig: fig, appearsIn: appearsIn, retired: retired, currentValue: currentValue, valueLoading: valueLoading, ownedRows: copyRows)
                } else {
                    EmptyStateView(message: L("detail_set_not_found"), image: "error_state")
                }
            }
        }
        .bwScreen()
        .navigationTitle(fig?.name ?? figNum)
        .navigationBarTitleDisplayMode(.inline)
        .itemSheets()
        .task(id: figNum) { await load() }
        .onChange(of: copyRows.map(\.updatedAt)) { _, _ in
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                currentValue = await values.fetch(forFig: figNum)
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            fig = try await CatalogRepository.shared.fetchMinifig(figNum)
            phase = .loaded
            guard fig != nil else { return }
            async let sets = (try? await CatalogRepository.shared.fetchSets(forMinifig: figNum)) ?? []
            currentValue = await values.fetch(forFig: figNum)
            valueLoading = false
            appearsIn = await sets
        } catch is CancellationError {
        } catch {
            phase = .failed
        }
    }
}

private struct MinifigContent: View {
    let fig: Minifig
    let appearsIn: [CatalogSet]
    let retired: Bool?
    let currentValue: CurrentValue?
    let valueLoading: Bool
    let ownedRows: [CollectionCopy]

    @Environment(AppSettings.self) private var settings
    @Environment(AuthService.self) private var auth
    @Environment(OwnershipIndex.self) private var ownership
    @Environment(ItemSheetCoordinator.self) private var sheets

    private var asSet: CatalogSet { .fromMinifig(fig) }

    var body: some View {
        let currency = settings.currency
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                Button { sheets.showGallery([fig.imageUrl].compactMap { $0 }) } label: {
                    RemoteImage([fig.imageUrl], maxPointSize: 320)
                        .frame(maxWidth: .infinity).frame(height: 230)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                Text(fig.name).font(.title3.weight(.bold)).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    if ownership.isOwnedOrSold(fig.figNum) {
                        Button { sheets.details(asSet, tab: ownership.owned.contains(fig.figNum) ? .collection : .sales) } label: {
                            Label(L("action_see_detail"), systemImage: "checkmark")
                        }
                        .buttonStyle(.bwSecondary)
                    } else {
                        Button { sheets.add(asSet, auth: auth) } label: { Label(L("action_add"), systemImage: "plus") }
                            .buttonStyle(.bwPrimary)
                        WishlistHeroButton(item: asSet, isWishlisted: ownership.wishlisted.contains(fig.figNum))
                    }
                }
            }
            .bwCard(padding: 16)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L("minifig_details")).padding(.bottom, 6)
                DetailRow(L("minifig_number"), value: fig.figNum)
                Divider()
                DetailRow(label: L("minifig_in_sets_label")) {
                    HStack(spacing: 8) {
                        Text(String(fig.setCount)).font(.subheadline.weight(.medium))
                        if fig.setCount == 1 { StatusBadge(status: .exclusive, labelOverride: L("minifig_exclusive")) }
                    }
                }
                if !fig.themes.isEmpty {
                    Divider()
                    DetailRow(L("meta_theme"), value: fig.themes.joined(separator: ", "))
                }
                if let retired {
                    Divider()
                    DetailRow(label: L("detail_availability")) {
                        StatusBadge(status: retired ? .retired : .available, labelOverride: retired ? L("status_retired") : L("status_retail"))
                    }
                }
            }
            .bwCard(padding: 16)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: L("detail_pricing")).padding(.bottom, 6)
                DetailRow(label: L("current_value")) {
                    ValueLine(label: "", value: currentValue, isLoading: valueLoading, font: .subheadline)
                }
                if !ownedRows.isEmpty {
                    let owned = DisplayBuilder.collectionItem(ownedRows)
                    Divider()
                    DetailRow(label: L("detail_my_collection")) {
                        Text(verbatim: "\(L("detail_total_paid")) \(Money.formatIn(owned.totalPaid(in: currency), currency)) · ×\(owned.totalQty)")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            .bwCard(padding: 16)

            if !appearsIn.isEmpty {
                SectionHeader(title: L("minifig_appears_in"))
                ForEach(appearsIn) { SetResultCard(set: $0) }
            }
        }
        .padding(.horizontal, Bw.gutter).padding(.bottom, 28)
    }
}
