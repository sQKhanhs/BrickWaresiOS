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
        owned = Set(copies.map(\.variantKey))
        wishlisted = Set(wishes.map(\.variantKey))
        sold = Set(sales.map(\.variantKey))
    }
}

/// The branded cold-start splash, ported from Android's `SplashScreen`: the brand ground (a bg → surface
/// gradient with a soft yellow glow), the app-icon tile that springs into place with a slight overshoot,
/// then the two-tone wordmark and a yellow ring spinner fading up. `RootView` holds it for a minimum beat
/// (1.4 s, Android's `SPLASH_MIN_MS`) and cross-fades into the app.
struct SplashView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var logoIn = false
    @State private var contentIn = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Bw.bg, Bw.surface], startPoint: .top, endPoint: .bottom)

            // Soft brand glow, nudged up to sit behind the tile (which leads the column).
            RadialGradient(colors: [Bw.yellow.opacity(colorScheme == .dark ? 0.16 : 0.24), .clear],
                           center: .center, startRadius: 0, endRadius: 170)
                .frame(width: 340, height: 340)
                .offset(y: -36)

            VStack(spacing: 26) {
                // App-icon tile — continuity from the home-screen icon the user just tapped.
                Image("brand_logo")
                    .resizable().scaledToFit()
                    .frame(width: 112, height: 112)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                    .scaleEffect(logoIn ? 1 : 0.72)
                BrandWordmark(size: 34)
                    .opacity(contentIn ? 1 : 0)
            }

            SplashSpinner()
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 64)
                .opacity(contentIn ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            // Android: spring(dampingRatio 0.5, stiffness Low = 200) → response 2π/√200 ≈ 0.44 s.
            withAnimation(reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.5)) { logoIn = true }
            // Android: tween(600, FastOutSlowInEasing) = cubic-bezier(0.4, 0, 0.2, 1).
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.6)) { contentIn = true }
        }
        .accessibilityHidden(true)
    }
}

/// Indeterminate yellow ring — Android's `CircularProgressIndicator` (26 pt, 2.5 pt stroke).
private struct SplashSpinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Bw.yellow, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: 26, height: 26)
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
