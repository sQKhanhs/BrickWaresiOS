import BackgroundTasks
import Foundation
import SwiftData
import UIKit
import UserNotifications
import os

/// Notifies about a wishlist item exactly once, when its status actually CHANGES to retired.
///
/// "Newly retired" = retired now ∩ last-seen wishlist − last-seen retired — so the first run
/// baselines silently, a set wishlisted after it retired never alerts, and each retirement alerts one
/// time. Delivered as an in-app toast when the app is frontmost, else as a local notification whose
/// tap opens the Wishlist tab.
///
/// iOS gives no guaranteed daily cadence (BGAppRefresh is best-effort), so the same check also runs
/// every time the app returns to the foreground.
@MainActor
enum RetirementAlerts {
    static let taskIdentifier = "com.senniapp.brickwares.retirement-check"
    private static let notificationId = "retirement-alert"
    private static let log = Logger(subsystem: "com.senniapp.brickwares", category: "RetirementAlerts")
    private static var container: ModelContainer?

    // MARK: Wiring

    /// Call once at launch, before the app finishes launching (BGTaskScheduler requirement).
    static func register(container: ModelContainer) {
        self.container = container
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor in
                scheduleNext()
                let ok = await run(foreground: false, router: nil)
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleNext() {
        guard AppSettings.shared.retirementAlerts else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 3600)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            log.info("BG refresh not scheduled: \(error.localizedDescription)")
        }
    }

    static func cancelScheduled() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    static func checkOnForeground(router: AppRouter) async {
        _ = await run(foreground: true, router: router)
    }

    // MARK: Permission

    enum Permission { case granted, denied }

    /// Requests notification permission (the opt-in toggle is what triggers the system prompt).
    static func requestPermission() async -> Permission {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default:
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return ok ? .granted : .denied
        }
    }

    // MARK: The check

    private static func run(foreground: Bool, router: AppRouter?) async -> Bool {
        guard AppSettings.shared.retirementAlerts, let container else { return true }
        let rows = (try? WishlistItem.fetchActive(in: container.mainContext)) ?? []
        // Only diff against AUTHORITATIVE statuses: force-refresh the referenced catalog first, and
        // skip the evaluation entirely when that fails (stored statuses may be stale either way).
        var keys = CatalogOverlay.ReferencedKeys()
        rows.forEach { keys.add(kind: $0.itemKind, setNumber: $0.setNumber, figNum: $0.figNum) }
        do { try await CatalogOverlay.shared.load(keys) } catch { return false }

        let entries = DisplayBuilder.wishlist(rows)
        let names = evaluate(entries)
        guard !names.isEmpty, AuthService.shared.state != .signedOut else { return true }

        let message = names.count == 1 ? L("notif_retired_one", names[0]) : L("notif_retired_many", names.count)
        if foreground, UIApplication.shared.applicationState == .active {
            router?.showToast(message)
        } else {
            await notify(message)
        }
        return true
    }

    /// The once-per-retirement diff. Idempotent: after a hit the newly-retired items are recorded,
    /// so re-evaluating the same data notifies nothing. Returns the newly-retired item names.
    static func evaluate(_ items: [WishlistEntry]) -> [String] {
        let settings = AppSettings.shared
        let current = Set(items.map(\.setNumber))
        let retiredNow = Set(items.filter { $0.status == .retired }.map(\.setNumber))
        let lastWishlist = settings.lastWishlist
        let lastRetired = settings.lastRetired
        let newly = retiredNow.filter { lastWishlist.contains($0) && !lastRetired.contains($0) }
        settings.lastWishlist = current
        settings.lastRetired = retiredNow
        return items.filter { newly.contains($0.setNumber) }.map(\.name)
    }

    private static func notify(_ text: String) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = L("notif_retired_title")
        content.body = text
        content.sound = .default
        content.userInfo = ["open_tab": "wishlist"]
        try? await center.add(UNNotificationRequest(identifier: notificationId, content: content, trigger: nil))
    }
}

/// Routes a notification tap to the Wishlist tab, and lets the alert show as a banner in-app.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let onOpenWishlist: @MainActor () -> Void

    init(onOpenWishlist: @escaping @MainActor () -> Void) {
        self.onOpenWishlist = onOpenWishlist
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.content.userInfo["open_tab"] as? String == "wishlist" {
            await onOpenWishlist()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
