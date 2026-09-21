import Foundation
import Supabase
import UIKit

enum FeedbackCategory: String, CaseIterable, Identifiable, Sendable {
    case bug, feature, other
    var id: String { rawValue }
}

/// Settings → Send feedback. Submits through the `submit_feedback` RPC — the only way into the
/// `feedback` table; validation, spam rate limits and the caller's identity are applied server-side.
/// Works signed in or out; signed-out submissions carry the per-install id as their rate-limit key.
enum FeedbackService {
    enum Result: Sendable { case sent, rateLimited, invalid, failed }

    private struct Params: Encodable, Sendable {
        var p_message: String
        var p_contact_email: String?
        var p_app_version: String
        var p_os_version: String
        var p_device: String
        var p_locale: String
        var p_install_id: String
        var p_category: String
    }

    @MainActor
    static func send(message: String, contactEmail: String?, category: FeedbackCategory) async -> Result {
        let params = Params(
            p_message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            p_contact_email: contactEmail?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            p_app_version: AppConfig.appVersion,
            p_os_version: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            p_device: "Apple \(deviceModel)",
            p_locale: Locale.current.identifier(.bcp47),
            p_install_id: AppSettings.installId,
            p_category: category.rawValue
        )
        return await submit(params)
    }

    @concurrent
    private static func submit(_ params: Params) async -> Result {
        let client = SupabaseProvider.client
        do {
            try await withTimeout(seconds: 15) { _ = try await client.rpc("submit_feedback", params: params).execute() }
            return .sent
        } catch {
            let text = String(describing: error) + error.localizedDescription
            if text.contains("feedback_rate_limited") { return .rateLimited }
            if text.contains("feedback_invalid") { return .invalid }
            return .failed
        }
    }

    /// Hardware identifier ("iPhone17,1"); the simulator reports its host model.
    private static var deviceModel: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
