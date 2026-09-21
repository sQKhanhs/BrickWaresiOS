import Foundation
import Network
import Observation
import SwiftUI

/// User-facing preferences, persisted in UserDefaults and observable so views re-render on change.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let currency = "prefs.app_currency"
        static let theme = "prefs.theme_mode"
        static let setThemes = "prefs.favorites.set_themes"
        static let minifigThemes = "prefs.favorites.minifig_themes"
        static let retirementAlerts = "prefs.retirement_alerts.enabled"
        static let lastWishlist = "prefs.retirement_alerts.last_wishlist"
        static let lastRetired = "prefs.retirement_alerts.last_retired"
        static let avatar = "prefs.avatar"
        static let installId = "prefs.install_id"
    }

    enum ThemeMode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Avatar: String, CaseIterable, Identifiable {
        case male, female
        var id: String { rawValue }
        var assetName: String { self == .male ? "avatar_m" : "avatar_f" }
    }

    private let defaults = UserDefaults.standard

    /// Display currency. Default **USD** — the canonical base, so prices render exactly out of the
    /// box; ₫ is opt-in. Only changes how amounts are shown and how price inputs are read.
    var currency: AppCurrency { didSet { defaults.set(currency.rawValue, forKey: Key.currency) } }

    /// iOS adds "System" (idiomatic here) on top of Android's Light/Dark.
    var themeMode: ThemeMode { didSet { defaults.set(themeMode.rawValue, forKey: Key.theme) } }

    var avatar: Avatar { didSet { defaults.set(avatar.rawValue, forKey: Key.avatar) } }

    /// Favorited theme names for the Search browse — set-themes and minifig-themes are independent.
    var favoriteSetThemes: Set<String> { didSet { defaults.set(Array(favoriteSetThemes), forKey: Key.setThemes) } }
    var favoriteMinifigThemes: Set<String> { didSet { defaults.set(Array(favoriteMinifigThemes), forKey: Key.minifigThemes) } }

    /// Retirement alerts toggle (default OFF — opting in is what triggers the notification prompt).
    var retirementAlerts: Bool { didSet { defaults.set(retirementAlerts, forKey: Key.retirementAlerts) } }

    /// Bumped when live FX rates land, so money text re-renders with the fresh rate.
    private(set) var ratesRevision = 0

    private init() {
        currency = AppCurrency(rawValue: defaults.string(forKey: Key.currency) ?? "") ?? .usd
        themeMode = ThemeMode(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        avatar = Avatar(rawValue: defaults.string(forKey: Key.avatar) ?? "") ?? .male
        favoriteSetThemes = Set(defaults.stringArray(forKey: Key.setThemes) ?? [])
        favoriteMinifigThemes = Set(defaults.stringArray(forKey: Key.minifigThemes) ?? [])
        retirementAlerts = defaults.bool(forKey: Key.retirementAlerts)
    }

    func ratesDidLoad() { ratesRevision += 1 }

    /// Account switch / deletion: the next account must not inherit the previous one's bookmarks.
    func clearFavorites() {
        favoriteSetThemes = []
        favoriteMinifigThemes = []
    }

    // Once-per-retirement bookkeeping for the alert detector (not observed by views).
    @ObservationIgnored var lastWishlist: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.lastWishlist) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.lastWishlist) }
    }

    @ObservationIgnored var lastRetired: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.lastRetired) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.lastRetired) }
    }

    /// Per-install random id — only the rate-limit key for signed-out feedback.
    nonisolated static var installId: String {
        if let id = UserDefaults.standard.string(forKey: Key.installId) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: Key.installId)
        return id
    }
}

/// App-wide online/offline signal. Drives sync-on-reconnect and gating of network-only actions.
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var isOnline = true
    /// Fired on an offline → online transition only (not for the initial value).
    @ObservationIgnored var onReconnect: (() -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var seeded = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "brickwares.connectivity"))
    }

    private func update(_ online: Bool) {
        let was = isOnline
        if isOnline != online { isOnline = online }
        if seeded, !was, online { onReconnect?() }
        seeded = true
    }
}
