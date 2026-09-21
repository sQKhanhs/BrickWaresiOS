import Observation
import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home, collection, wishlist, search, settings
}

/// Detail destinations, pushed onto the current tab's `NavigationStack` (the typed replacement for
/// Android's string-encoded `s:` / `f:` / `n:` / `t:` detail-stack entries).
enum Route: Hashable {
    /// `CatalogSet.id` ("<number>-<variant>") or a bare set number.
    case set(String)
    case minifig(String)
    case newSets
    case theme(name: String, subtheme: String?, minifigs: Bool)
}

struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    var text: String
}

/// App-level navigation state: the selected tab, one path per tab, and the transient toast.
@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .home
    var homePath: [Route] = []
    var collectionPath: [Route] = []
    var wishlistPath: [Route] = []
    var searchPath: [Route] = []
    var settingsPath: [Route] = []

    private(set) var toast: ToastMessage?
    /// Bumped when the Search tab is re-selected, so the Search screen resets to its browse home.
    private(set) var searchResetTick = 0

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Tab selection with the native "tap the current tab again → pop to root" behavior. Re-tapping
    /// Search also resets it to the browse home.
    var tabSelection: Binding<AppTab> {
        Binding(
            get: { self.tab },
            set: { new in
                if new == self.tab {
                    self.popToRoot(new)
                    if new == .search { self.searchResetTick += 1 }
                } else {
                    self.tab = new
                }
            }
        )
    }

    /// Push a detail onto the tab the user is currently on.
    func open(_ route: Route) {
        switch tab {
        case .home: homePath.append(route)
        case .collection: collectionPath.append(route)
        case .wishlist: wishlistPath.append(route)
        case .search: searchPath.append(route)
        case .settings: settingsPath.append(route)
        }
    }

    func go(to tab: AppTab) {
        self.tab = tab
    }

    func popToRoot(_ tab: AppTab) {
        switch tab {
        case .home: homePath = []
        case .collection: collectionPath = []
        case .wishlist: wishlistPath = []
        case .search: searchPath = []
        case .settings: settingsPath = []
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = ToastMessage(text: text) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
    }
}

/// Wraps a tab's root in its own `NavigationStack` and registers the shared destinations once.
struct TabStack<Root: View>: View {
    @Binding var path: [Route]
    @ViewBuilder var root: () -> Root

    var body: some View {
        NavigationStack(path: $path) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .set(let key): SetDetailView(catalogKey: key)
                    case .minifig(let figNum): MinifigDetailView(figNum: figNum)
                    case .newSets: NewSetsView()
                    case .theme(let name, let subtheme, let minifigs):
                        ThemeResultsView(theme: name, initialSubtheme: subtheme, minifigMode: minifigs)
                    }
                }
        }
    }
}
