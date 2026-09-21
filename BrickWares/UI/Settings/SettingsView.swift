import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AuthService.self) private var auth
    @Environment(AppSettings.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(Connectivity.self) private var connectivity
    @Environment(SyncScheduler.self) private var sync
    @Environment(CollectionService.self) private var collection
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL

    @State private var showDeleteConfirm = false
    @State private var showSetPassword = false
    @State private var showAvatarPicker = false
    @State private var showFeedback = false
    @State private var showNotificationsBlocked = false
    @State private var showNoInternet: String?
    @State private var newPassword = ""

    @State private var exportDocument: CSVDocument?
    @State private var showImporter = false
    @State private var pendingImport: String?
    @State private var importing = false

    var body: some View {
        @Bindable var settings = settings
        List {
            accountSection

            Section(L("settings_section_display")) {
                Button { openAppSettings() } label: {
                    LabeledContent {
                        HStack(spacing: 4) {
                            Text(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en")?.capitalized ?? "English")
                            Image(systemName: "arrow.up.forward.app").font(.caption)
                        }
                        .foregroundStyle(Bw.textMuted)
                    } label: {
                        Label(L("settings_language"), systemImage: "globe").foregroundStyle(Bw.text)
                    }
                }
                Picker(selection: $settings.currency) {
                    ForEach(AppCurrency.allCases) { Text(verbatim: "\($0.rawValue) (\($0.symbol))").tag($0) }
                } label: { Label(L("settings_currency"), systemImage: "banknote") }
                if settings.currency == .vnd {
                    Text(L("settings_currency_vnd_note")).font(.caption).foregroundStyle(Bw.textMuted)
                }
                Picker(selection: $settings.themeMode) {
                    Text(L("theme_system")).tag(AppSettings.ThemeMode.system)
                    Text(L("theme_light")).tag(AppSettings.ThemeMode.light)
                    Text(L("theme_dark")).tag(AppSettings.ThemeMode.dark)
                } label: { Label(L("settings_theme"), systemImage: "circle.lefthalf.filled") }
            }

            Section(L("settings_section_data")) {
                Button { exportDocument = CSVDocument(text: collection.exportCSV()) } label: {
                    Label(L("settings_export_csv"), systemImage: "square.and.arrow.up")
                }
                Button {
                    // Import overwrites + syncs, so it needs a connection.
                    if connectivity.isOnline { showImporter = true } else { showNoInternet = L("settings_no_internet_body") }
                } label: { Label(L("settings_import_csv"), systemImage: "square.and.arrow.down") }
            }
            .disabled(!auth.isSignedIn)

            Section(L("settings_section_notifications")) {
                Toggle(isOn: Binding(get: { settings.retirementAlerts }, set: setRetirementAlerts)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings_retirement_alerts"))
                            Text(L("settings_retirement_alerts_desc")).font(.caption).foregroundStyle(Bw.textMuted)
                        }
                    } icon: { Image(systemName: "bell.badge") }
                }
            }

            Section(L("settings_section_privacy")) {
                Link(destination: AppConfig.privacyURL) { Label(L("settings_privacy_policy"), systemImage: "hand.raised") }
                Link(destination: AppConfig.termsURL) { Label(L("settings_terms"), systemImage: "doc.text") }
            }

            Section(L("settings_section_about")) {
                Button {
                    if connectivity.isOnline { showFeedback = true } else { showNoInternet = L("settings_feedback_no_internet_body") }
                } label: { Label(L("settings_send_feedback"), systemImage: "bubble.left.and.text.bubble.right") }
                Button { requestReview() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("settings_rate"))
                            Text(L("settings_rate_subtitle")).font(.caption).foregroundStyle(Bw.textMuted)
                        }
                    } icon: { Image(systemName: "star") }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("settings_data_attribution"), systemImage: "info.circle")
                    Text(L("settings_attribution_body")).font(.caption).foregroundStyle(Bw.textMuted)
                }
                LabeledContent(L("settings_version_label"), value: AppConfig.appVersion)
            }
        }
        .tint(Bw.link2)
        .navigationTitle(L("settings_title"))
        .overlay { if importing { ImportingOverlay() } }
        .sheet(isPresented: $showFeedback) { FeedbackSheet() }
        .sheet(isPresented: $showAvatarPicker) { AvatarPicker() }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument, contentType: .commaSeparatedText,
            defaultFilename: "brickwares-\(LocalDay.today.iso)"
        ) { result in
            router.showToast(L((try? result.get()) != nil ? "toast_export_success" : "toast_export_failed"))
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            guard let url = try? result.get() else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                pendingImport = text
            } else {
                router.showToast(L("toast_import_failed"))
            }
        }
        .alert(L("settings_import_confirm_title"), isPresented: Binding(get: { pendingImport != nil && !importing }, set: { if !$0, !importing { pendingImport = nil } })) {
            Button(L("action_import"), role: .destructive) { runImport() }
            Button(L("action_cancel"), role: .cancel) { pendingImport = nil }
        } message: { Text(L("settings_import_confirm_body")) }
        .alert(L("settings_delete_confirm_title"), isPresented: $showDeleteConfirm) {
            Button(L("action_delete"), role: .destructive) { deleteAccount() }
            Button(L("action_cancel"), role: .cancel) {}
        } message: { Text(L("settings_delete_confirm_body")) }
        .alert(L("set_password_title"), isPresented: $showSetPassword) {
            SecureField(L("login_password"), text: $newPassword)
            Button(L("action_save")) { savePassword() }
            Button(L("action_cancel"), role: .cancel) { newPassword = "" }
        } message: { Text(L("set_password_body")) }
        .alert(L("settings_notifications_blocked_title"), isPresented: $showNotificationsBlocked) {
            Button(L("settings_open_notification_settings")) { openAppSettings() }
            Button(L("action_cancel"), role: .cancel) {}
        } message: { Text(L("settings_notifications_disabled")) }
        .alert(L("settings_no_internet_title"), isPresented: Binding(get: { showNoInternet != nil }, set: { if !$0 { showNoInternet = nil } })) {
            Button(L("action_ok"), role: .cancel) {}
        } message: { Text(showNoInternet ?? "") }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        Section(L("settings_section_account")) {
            if let user = auth.user {
                HStack(spacing: 14) {
                    Button { showAvatarPicker = true } label: {
                        Image(settings.avatar.assetName).resizable().scaledToFill()
                            .frame(width: 58, height: 58).clipShape(Circle())
                            .overlay(Circle().strokeBorder(Bw.yellow, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("settings_change_avatar_cd"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName).font(.headline)
                        Text(user.email).font(.subheadline).foregroundStyle(Bw.textMuted).lineLimit(1)
                        if sync.isSyncing { Text(L("sync_in_progress")).font(.caption).foregroundStyle(Bw.textFaint) }
                    }
                }
                .padding(.vertical, 4)

                if user.isSocialOnly {
                    Button { newPassword = ""; showSetPassword = true } label: { Label(L("settings_set_password"), systemImage: "key") }
                        .disabled(!connectivity.isOnline)
                }
                Button {
                    Task { await auth.signOut(); router.showToast(L("toast_signed_out")) }
                } label: { Label(L("settings_sign_out"), systemImage: "rectangle.portrait.and.arrow.right") }
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label(L("settings_delete_account"), systemImage: "trash").foregroundStyle(Bw.error)
                }
                .disabled(!connectivity.isOnline)
            } else {
                Button { auth.requestSignIn() } label: {
                    Label(L("settings_sign_in"), systemImage: "person.crop.circle.badge.plus").fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: Actions

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func setRetirementAlerts(_ on: Bool) {
        guard on else {
            settings.retirementAlerts = false
            RetirementAlerts.cancelScheduled()
            return
        }
        Task {
            if await RetirementAlerts.requestPermission() == .granted {
                settings.retirementAlerts = true
                RetirementAlerts.scheduleNext()
            } else {
                showNotificationsBlocked = true
            }
        }
    }

    private func savePassword() {
        let password = newPassword
        newPassword = ""
        guard password.count >= 6 else { router.showToast(L("login_err_password_short", 6)); return }
        Task {
            switch await auth.setPassword(password) {
            case .success: router.showToast(L("toast_password_set"))
            case .passwordAlreadySet: router.showToast(L("toast_password_already_set"))
            case .tooManyRequests: router.showToast(L("login_err_too_many"))
            default: router.showToast(L("toast_password_failed"))
            }
        }
    }

    private func deleteAccount() {
        Task {
            let ok = await auth.deleteAccount { await sync.wipeEverything() }
            router.showToast(L(ok ? "toast_account_deleted" : "toast_delete_account_failed"))
        }
    }

    private func runImport() {
        guard let text = pendingImport else { return }
        importing = true
        Task {
            defer { importing = false; pendingImport = nil }
            do {
                let count = try await collection.importCSV(text)
                router.showToast(L("toast_import_success", count))
            } catch CollectionCSV.ImportError.tooNew {
                router.showToast(L("toast_import_too_new"))
            } catch {
                router.showToast(L("toast_import_failed"))
            }
        }
    }
}

/// Non-dismissable progress while an import overwrites + syncs.
private struct ImportingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Bw.yellow)
                Text(L("settings_importing")).font(.subheadline.weight(.semibold))
            }
            .padding(28)
            .background(Bw.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct AvatarPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            HStack(spacing: 28) {
                ForEach(AppSettings.Avatar.allCases) { avatar in
                    Button {
                        settings.avatar = avatar
                        dismiss()
                    } label: {
                        Image(avatar.assetName).resizable().scaledToFill()
                            .frame(width: 104, height: 104).clipShape(Circle())
                            .overlay(Circle().strokeBorder(settings.avatar == avatar ? Bw.yellow : Bw.border, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bwScreen()
            .navigationTitle(L("settings_choose_avatar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("action_close")) { dismiss() } } }
        }
        .presentationDetents([.height(260)])
    }
}

private struct FeedbackSheet: View {
    private static let minLength = 5
    private static let maxLength = 2000

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthService.self) private var auth
    @Environment(AppRouter.self) private var router

    @State private var category: FeedbackCategory = .other
    @State private var message = ""
    @State private var email = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(L("feedback_body")).font(.subheadline).foregroundStyle(Bw.textMuted) }
                Section {
                    Picker(L("feedback_category_label"), selection: $category) {
                        Text(L("feedback_category_bug")).tag(FeedbackCategory.bug)
                        Text(L("feedback_category_feature")).tag(FeedbackCategory.feature)
                        Text(L("feedback_category_other")).tag(FeedbackCategory.other)
                    }
                    TextField(L("feedback_placeholder"), text: $message, axis: .vertical)
                        .lineLimit(5...12)
                        .onChange(of: message) { _, new in if new.count > Self.maxLength { message = String(new.prefix(Self.maxLength)) } }
                } footer: {
                    HStack {
                        if let error { Text(error).foregroundStyle(Bw.error) }
                        Spacer()
                        Text(L("feedback_counter", message.count, Self.maxLength))
                    }
                }
                // Signed in, the server uses the account email; only guests can leave one.
                if !auth.isSignedIn {
                    Section {
                        TextField(L("feedback_email_placeholder"), text: $email)
                            .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle(L("feedback_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("action_cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else { Button(L("action_send"), action: send).fontWeight(.semibold) }
                }
            }
        }
        .interactiveDismissDisabled(sending)
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minLength else { error = L("feedback_err_short", Self.minLength); return }
        let mail = email.trimmingCharacters(in: .whitespaces)
        if !mail.isEmpty, !(mail.contains("@") && mail.contains(".")) { error = L("feedback_err_email"); return }
        error = nil
        sending = true
        Task {
            let result = await FeedbackService.send(message: text, contactEmail: mail.nilIfEmpty, category: category)
            sending = false
            switch result {
            case .sent:
                router.showToast(L("toast_feedback_sent"))
                dismiss()
            case .rateLimited: error = L("toast_feedback_rate_limited")
            case .invalid, .failed: error = L("toast_feedback_failed")
            }
        }
    }
}
