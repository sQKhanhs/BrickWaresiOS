import SwiftData
import SwiftUI

/// The app frame: five tabs (each with its own navigation stack), the branded splash held while the
/// persisted session restores, the on-demand login sheet, and the toast. There is **no login wall** —
/// signed-out users browse freely and write features raise the login sheet when needed.
struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AuthService.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(CatalogOverlay.self) private var overlay
    @Environment(SyncScheduler.self) private var sync
    @Environment(\.scenePhase) private var scenePhase

    // The three user tables, observed here only to keep the user-scoped catalog overlay in step.
    @Query(filter: #Predicate<CollectionCopy> { !$0.tombstoned }) private var copies: [CollectionCopy]
    @Query(filter: #Predicate<WishlistItem> { !$0.tombstoned }) private var wishes: [WishlistItem]
    @Query(filter: #Predicate<Sale> { !$0.tombstoned }) private var sales: [Sale]

    @State private var minSplashElapsed = false
    @State private var ownership = OwnershipIndex()

    private var showSplash: Bool { auth.isLoading || !minSplashElapsed }
    private var referencedKeys: CatalogOverlay.ReferencedKeys { DisplayBuilder.referencedKeys(copies, wishes, sales) }

    var body: some View {
        @Bindable var router = router
        @Bindable var auth = auth

        ZStack {
            TabView(selection: router.tabSelection) {
                Tab(L("nav_home"), systemImage: "house", value: AppTab.home) {
                    TabStack(path: $router.homePath) { HomeView() }
                }
                Tab(L("nav_collection"), systemImage: "shippingbox", value: AppTab.collection) {
                    TabStack(path: $router.collectionPath) { CollectionView() }
                }
                Tab(L("nav_wishlist"), systemImage: "heart", value: AppTab.wishlist) {
                    TabStack(path: $router.wishlistPath) { WishlistView() }
                }
                Tab(L("nav_search"), systemImage: "magnifyingglass", value: AppTab.search) {
                    TabStack(path: $router.searchPath) { SearchView() }
                }
                Tab(L("nav_settings"), systemImage: "gearshape", value: AppTab.settings) {
                    TabStack(path: $router.settingsPath) { SettingsView() }
                }
            }
            .tint(Bw.link2)

            if showSplash {
                SplashView().transition(.opacity).zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showSplash)
        .overlay(alignment: .bottom) { ToastOverlay(toast: router.toast) }
        .sheet(isPresented: $auth.showLogin) { LoginView() }
        .environment(ownership)
        .preferredColorScheme(settings.themeMode.colorScheme)
        .task {
            try? await Task.sleep(for: .seconds(1.4))
            minSplashElapsed = true
        }
        // Rebuild the user-scoped catalog overlay whenever the referenced set/fig keys change.
        .task(id: referencedKeys) { await overlay.refresh(referencedKeys) }
        .onChange(of: OwnershipKey(copies, wishes, sales), initial: true) { _, key in
            ownership.update(owned: key.owned, wishlisted: key.wishlisted, sold: key.sold)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            sync.requestSync()
            Task { await RetirementAlerts.checkOnForeground(router: router) }
        }
    }
}

private struct OwnershipKey: Equatable {
    var owned: Set<String>
    var wishlisted: Set<String>
    var sold: Set<String>

    @MainActor
    init(_ copies: [CollectionCopy], _ wishes: [WishlistItem], _ sales: [Sale]) {
        owned = Set(copies.map(\.setNumber))
        wishlisted = Set(wishes.map(\.setNumber))
        sold = Set(sales.map(\.setNumber))
    }
}

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Bw.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("brand_logo")
                    .resizable().scaledToFit()
                    .frame(width: 148, height: 148)
                    // The artwork has an opaque white backdrop, so present it as an app-icon tile.
                    .clipShape(RoundedRectangle(cornerRadius: 33, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                    .scaleEffect(appeared ? 1 : 0.86)
                Text(verbatim: "BrickWares")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(Bw.text)
            }
            .opacity(appeared ? 1 : 0)
        }
        .onAppear { withAnimation(.spring(duration: 0.7)) { appeared = true } }
        .accessibilityHidden(true)
    }
}

private struct ToastOverlay: View {
    let toast: ToastMessage?

    var body: some View {
        if let toast {
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Bw.bg)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Bw.text.opacity(0.92), in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.horizontal, 24)
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityAddTraits(.isStaticText)
                .onAppear { UIAccessibility.post(notification: .announcement, argument: toast.text) }
        }
    }
}
