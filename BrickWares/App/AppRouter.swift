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
    private(set) var tab: AppTab = .home
    var homePath: [Route] = []
    var collectionPath: [Route] = []
    var wishlistPath: [Route] = []
    var searchPath: [Route] = []
    var settingsPath: [Route] = []

    private(set) var toast: ToastMessage?
    /// Bumped whenever the Search tab is entered or re-selected, so the Search screen resets to its
    /// browse home.
    private(set) var searchResetTick = 0

    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// The tab bar's selection.
    var tabSelection: Binding<AppTab> {
        Binding(get: { self.tab }, set: { self.go(to: $0) })
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

    /// Selects `tab`, which always opens at its HOME page. A tab does not keep a detail open while the
    /// user is elsewhere: the tab being left is popped to its root, like Android clearing its detail
    /// stack on every tab switch (iOS' own default — each tab remembers where it was — read as the app
    /// "being somewhere else" on return). Tapping the tab you are already on pops it to its root too, the
    /// native gesture. Entering or re-tapping Search also resets it to the browse home.
    func go(to new: AppTab) {
        let old = tab
        // Off-screen (or about to be): no pop animation to play.
        var quiet = Transaction()
        quiet.disablesAnimations = new != old
        withTransaction(quiet) {
            popToRoot(old)
            popToRoot(new)
        }
        if new == .search { searchResetTick += 1 }
        tab = new
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
