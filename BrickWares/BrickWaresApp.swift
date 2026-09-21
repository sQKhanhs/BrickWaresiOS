import SwiftData
import SwiftUI
import UserNotifications

@main
struct BrickWaresApp: App {
    private let container: ModelContainer
    @State private var router: AppRouter
    @State private var sync: SyncScheduler
    @State private var collection: CollectionService
    private let notifications: NotificationRouter

    init() {
        do {
            container = try UserDataStore.makeContainer()
        } catch {
            // No destructive fallback on purpose (it would drop unpushed rows) — fail loudly instead.
            fatalError("Could not open the BrickWares data store: \(error)")
        }
        let scheduler = SyncScheduler(container: container)
        _sync = State(initialValue: scheduler)
        _collection = State(initialValue: CollectionService(container: container, sync: scheduler))

        // Sync triggers: (1) a session appearing, (2) offline → online, (3) each local write.
        AuthService.shared.onSignedIn = { user in Task { await scheduler.handleSignedIn(user) } }
        Connectivity.shared.onReconnect = { scheduler.requestSync() }
        AuthService.shared.start()

        // Retirement alerts: BG refresh handler must be registered before launch completes.
        RetirementAlerts.register(container: container)
        RetirementAlerts.scheduleNext()
        let appRouter = AppRouter()
        _router = State(initialValue: appRouter)
        notifications = NotificationRouter { appRouter.popToRoot(.wishlist); appRouter.go(to: .wishlist) }
        UNUserNotificationCenter.current().delegate = notifications
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(router)
                .environment(sync)
                .environment(collection)
                .environment(AuthService.shared)
                .environment(AppSettings.shared)
                .environment(ValueService.shared)
                .environment(CatalogOverlay.shared)
                .environment(Connectivity.shared)
                .task {
                    // Best-effort warm-ups, off the critical path.
                    async let fx = CurrencyConverter.shared.ensureRatesLoaded()
                    async let values: Void = ValueService.shared.warm()
                    if await fx { AppSettings.shared.ratesDidLoad() }
                    _ = await values
                }
        }
        .modelContainer(container)
    }
}
