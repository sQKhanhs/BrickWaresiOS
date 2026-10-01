import AuthenticationServices
import SwiftUI

/// The on-demand sign-in sheet: Apple / Google, or email + password with a 6-digit email-confirmation
/// step, plus the forgot-password flow (email → 6-digit recovery code → new password). Every email call
/// first acquires a Turnstile token (see `CaptchaGate`).
struct LoginView: View {
    private enum Mode { case signIn, signUp }

    /// Forgot-password flow; `.inactive` = the normal sign-in / sign-up form. Verifying the recovery code signs
    /// the user in, so `AuthService.holdLoginOpen` keeps this sheet up for the `newPassword` step.
    private enum ResetStep { case inactive, email, code, newPassword }

    private static let minPassword = AuthService.minPasswordLength
    private static let codeLength = 6
    private static let resendCooldown: TimeInterval = 60

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AuthService.self) private var auth
    @Environment(Connectivity.self) private var connectivity

    @State private var captcha = CaptchaGate()
    @State private var mode: Mode = .signIn
    @State private var reset: ResetStep = .inactive
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?

    // OTP step (sign-up confirmation and password reset share the code field)
    @State private var awaitingCode = false
    @State private var pendingEmail = ""
    /// GoTrue keeps the FIRST password when an unconfirmed email signs up again, so the latest
    /// attempt's password is re-applied after the code verifies.
    @State private var pendingPassword: String?
    @State private var code = ""
    @State private var resendAvailableAt = Date.distantPast
    @State private var appleNonce = Nonce()

    @FocusState private var focus: Field?
    private enum Field { case email, password, confirm, code }

    private var offline: Bool { !connectivity.isOnline }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    switch reset {
                    case .inactive: if awaitingCode { codeStep } else { credentialsStep }
                    case .email: resetEmailStep
                    case .code: resetCodeStep
                    case .newPassword: resetPasswordStep
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .bwScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    switch reset {
                    case .code:
                        Button(L("login_back")) { reset = .email; code = ""; error = nil; info = nil }
                    case .email:
                        Button(L("login_back")) { reset = .inactive; error = nil; info = nil }
                    case .newPassword:
                        // No Back from here. Closing leaves the user signed in with the old password —
                        // harmless: they proved the email is theirs and can run the flow again.
                        Button(L("action_close")) { dismiss() }
                    case .inactive:
                        if awaitingCode {
                            Button(L("login_back")) { awaitingCode = false; code = ""; error = nil; info = nil }
                        } else {
                            Button(L("action_close")) { dismiss() }
                        }
                    }
                }
            }
            .overlay { CaptchaHost(gate: captcha) }
        }
        .interactiveDismissDisabled(busy)
        .onDisappear { auth.holdLoginOpen = false }
    }

    // MARK: Step 1 — credentials

    @ViewBuilder private var credentialsStep: some View {
        Image("brand_logo").resizable().scaledToFit().frame(width: 84, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        Text(mode == .signIn ? L("login_welcome_back") : L("login_create_account")).font(.title2.weight(.bold))

        if offline { notice(L("login_offline"), color: Bw.error) }

        SignInWithAppleButton(.continue) { request in
            appleNonce = Nonce()
            request.requestedScopes = [.fullName, .email]
            request.nonce = appleNonce.sha256
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50).clipShape(Capsule())
        .disabled(busy || offline)

        Button { run { await auth.signInWithGoogle() } } label: {
            HStack(spacing: 10) {
                Text(verbatim: "G").font(.system(size: 19, weight: .heavy, design: .rounded)).foregroundStyle(Color(hex: 0x4285F4))
                Text(L("login_google"))
            }
        }
        .buttonStyle(.bwSecondary)
        .disabled(busy || offline)

        HStack {
            Rectangle().fill(Bw.border).frame(height: 1)
            Text(L("login_or")).font(.caption.weight(.semibold)).foregroundStyle(Bw.textMuted)
            Rectangle().fill(Bw.border).frame(height: 1)
        }

        VStack(spacing: 10) {
            field {
                TextField(L("login_email"), text: $email)
                    .textContentType(.username).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .email).submitLabel(.next).onSubmit { focus = .password }
            }
            field {
                // The length rule is stated upfront when CREATING a password; sign-in just asks for it.
                SecureField(mode == .signIn ? L("login_password") : L("login_password_new", Self.minPassword), text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .focused($focus, equals: .password)
                    .submitLabel(mode == .signIn ? .go : .next)
                    .onSubmit { if mode == .signIn { submitEmail() } else { focus = .confirm } }
            }
            if mode == .signUp {
                field {
                    SecureField(L("login_confirm_password"), text: $confirmPassword)
                        .textContentType(.newPassword).focused($focus, equals: .confirm)
                        .submitLabel(.go).onSubmit(submitEmail)
                }
            }
        }

        notices

        Button(action: submitEmail) {
            if busy { ProgressView().tint(Bw.onYellow) } else { Text(mode == .signIn ? L("action_sign_in") : L("login_signup_action")) }
        }
        .buttonStyle(.bwPrimary)
        .disabled(busy || offline)

        if mode == .signIn {
            Button(L("login_forgot_password"), action: forgotPassword)
                .font(.footnote.weight(.semibold)).foregroundStyle(Bw.link).disabled(busy || offline)
        }

        HStack(spacing: 2) {
            Text(mode == .signIn ? L("login_no_account") : L("login_have_account")).foregroundStyle(Bw.textMuted)
            Button(mode == .signIn ? L("login_signup_link") : L("action_sign_in")) {
                mode = mode == .signIn ? .signUp : .signIn
                error = nil; info = nil; confirmPassword = ""
            }
            .fontWeight(.semibold).foregroundStyle(Bw.link)
        }
        .font(.subheadline)

        legalLine
    }

    /// "By continuing, you agree to the Terms of Service and Privacy Policy", both names as links: the
    /// Terms say creating an account means agreeing to them, so the moment of sign-up has to point at them.
    private var legalLine: some View {
        let terms = L("settings_terms"), privacy = L("settings_privacy_policy")
        var text = AttributedString(L("login_legal_acceptance", terms, privacy))
        for (name, page) in [(terms, AppConfig.termsURL), (privacy, AppConfig.privacyURL)] {
            guard let range = text.range(of: name) else { continue }
            text[range].link = AppConfig.localized(page)
            text[range].underlineStyle = .single
        }
        return Text(text).font(.caption).foregroundStyle(Bw.textFaint).tint(Bw.link)
            .multilineTextAlignment(.center).padding(.top, 4)
    }

    // MARK: Step 2 — email confirmation code

    @ViewBuilder private var codeStep: some View {
        Image(systemName: "envelope.badge").font(.system(size: 44)).foregroundStyle(Bw.link2).padding(.top, 12)
        Text(L("login_confirm_title")).font(.title2.weight(.bold))
        Text(L("login_confirm_sent", pendingEmail)).font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center)

        codeField(onComplete: verifyCode)
        notices

        Button(action: verifyCode) {
            if busy { ProgressView().tint(Bw.onYellow) } else { Text(L("login_verify_action")) }
        }
        .buttonStyle(.bwPrimary)
        .disabled(busy || offline || code.count != Self.codeLength)

        resendRow(action: resendCode)
    }

    // MARK: Forgot password — email → 6-digit recovery code → new password

    @ViewBuilder private var resetEmailStep: some View {
        Image(systemName: "key.horizontal").font(.system(size: 44)).foregroundStyle(Bw.link2).padding(.top, 12)
        Text(L("login_reset_title")).font(.title2.weight(.bold))
        Text(L("login_reset_body")).font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center)

        if offline { notice(L("login_offline"), color: Bw.error) }

        field {
            TextField(L("login_email"), text: $email)
                .textContentType(.username).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .email).submitLabel(.go).onSubmit(sendResetCode)
        }
        .onAppear { if email.isEmpty { focus = .email } }

        notices

        Button(action: sendResetCode) {
            if busy { ProgressView().tint(Bw.onYellow) } else { Text(L("login_reset_send")) }
        }
        .buttonStyle(.bwPrimary)
        .disabled(busy || offline)
    }

    @ViewBuilder private var resetCodeStep: some View {
        Image(systemName: "envelope.badge").font(.system(size: 44)).foregroundStyle(Bw.link2).padding(.top, 12)
        Text(L("login_reset_title")).font(.title2.weight(.bold))
        // Conditional wording on purpose: the server never says whether the address has an account.
        Text(L("login_reset_sent", pendingEmail)).font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center)

        codeField(onComplete: verifyResetCode)
        notices

        Button(action: verifyResetCode) {
            if busy { ProgressView().tint(Bw.onYellow) } else { Text(L("login_verify_action")) }
        }
        .buttonStyle(.bwPrimary)
        .disabled(busy || offline || code.count != Self.codeLength)

        resendRow(action: sendResetCode)
    }

    @ViewBuilder private var resetPasswordStep: some View {
        Image(systemName: "lock.rotation").font(.system(size: 44)).foregroundStyle(Bw.link2).padding(.top, 12)
        Text(L("login_reset_title")).font(.title2.weight(.bold))
        Text(L("login_reset_new_body")).font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center)

        VStack(spacing: 10) {
            field {
                SecureField(L("login_password_new", Self.minPassword), text: $password)
                    .textContentType(.newPassword).focused($focus, equals: .password)
                    .submitLabel(.next).onSubmit { focus = .confirm }
            }
            field {
                SecureField(L("login_confirm_password"), text: $confirmPassword)
                    .textContentType(.newPassword).focused($focus, equals: .confirm)
                    .submitLabel(.go).onSubmit(saveNewPassword)
            }
        }
        .onAppear { focus = .password }

        notices

        Button(action: saveNewPassword) {
            if busy { ProgressView().tint(Bw.onYellow) } else { Text(L("login_reset_save")) }
        }
        .buttonStyle(.bwPrimary)
        .disabled(busy || offline)
    }

    // MARK: Pieces

    private func field(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(Bw.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Bw.borderStrong))
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote.weight(.medium)).foregroundStyle(color)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
    }

    @ViewBuilder private var notices: some View {
        if let error { notice(error, color: Bw.error) }
        if let info { notice(info, color: Bw.success) }
    }

    /// The 6-digit code field; submits itself once the last digit is in.
    private func codeField(onComplete: @escaping () -> Void) -> some View {
        field {
            TextField(L("login_code_hint"), text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit().weight(.semibold)).multilineTextAlignment(.center).tracking(6)
                .focused($focus, equals: .code)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(Self.codeLength))
                    if code.count == Self.codeLength { onComplete() }
                }
        }
        .onAppear { focus = .code }
    }

    private func resendRow(action: @escaping () -> Void) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
            HStack(spacing: 2) {
                Text(L("login_resend_prompt")).foregroundStyle(Bw.textMuted)
                if remaining > 0 {
                    Text(L("login_resend_in", remaining)).foregroundStyle(Bw.textFaint)
                } else {
                    Button(L("login_resend_code"), action: action).fontWeight(.semibold).foregroundStyle(Bw.link).disabled(busy || offline)
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: Actions

    private func run(_ operation: @escaping () async -> SignInResult) {
        guard !busy else { return }
        busy = true; error = nil; info = nil
        Task {
            let result = await operation()
            busy = false
            handle(result)
        }
    }

    /// Runs an email auth call behind the captcha gate.
    private func runWithCaptcha(_ operation: @escaping (String?) async -> SignInResult, then: ((SignInResult) -> Void)? = nil) {
        guard !busy else { return }
        busy = true; error = nil; info = nil
        focus = nil
        Task {
            let result: SignInResult
            switch await captcha.acquire() {
            case .failed: result = .captchaFailed
            case .disabled: result = await operation(nil)
            case .token(let token): result = await operation(token)
            }
            busy = false
            if let then { then(result) } else { handle(result) }
        }
    }

    private static func isEmail(_ mail: String) -> Bool {
        mail.contains("@") && mail.contains(".") && !mail.contains(" ")
    }

    private func submitEmail() {
        let mail = email.trimmingCharacters(in: .whitespaces)
        guard Self.isEmail(mail) else { error = L("login_err_invalid_email"); return }
        if mode == .signUp {
            guard password.count >= Self.minPassword else { error = L("login_err_password_short", Self.minPassword); return }
            guard password == confirmPassword else { error = L("login_err_password_mismatch"); return }
            let lang = Locale.current.language.languageCode?.identifier == "vi" ? "vi" : "en"
            let pwd = password
            runWithCaptcha({ await auth.signUp(email: mail, password: pwd, lang: lang, captchaToken: $0) }) { result in
                if result == .emailConfirmationRequired { pendingPassword = pwd }
                handle(result, email: mail)
            }
        } else {
            // Sign-in only needs SOME password: an account made before the 8-character rule still gets in.
            guard !password.isEmpty else { error = L("login_err_password_required"); return }
            let pwd = password
            runWithCaptcha({ await auth.signIn(email: mail, password: pwd, captchaToken: $0) }) { handle($0, email: mail) }
        }
    }

    private func verifyCode() {
        guard code.count == Self.codeLength else { return }
        let mail = pendingEmail, entered = code, reapply = pendingPassword
        run {
            let result = await auth.verifySignUpCode(email: mail, code: entered)
            if result == .success, let reapply { _ = await auth.setPassword(reapply) } // best-effort
            switch result {
            case .success, .networkError, .tooManyRequests: return result
            default: return .error("__code__")
            }
        }
    }

    private func resendCode() {
        let mail = pendingEmail
        runWithCaptcha({ await auth.resendSignUpCode(email: mail, captchaToken: $0) }) { result in
            if result == .success {
                code = ""
                info = L("login_code_resent")
                resendAvailableAt = Date().addingTimeInterval(Self.resendCooldown)
            } else {
                handle(result)
            }
        }
    }

    // MARK: Forgot password

    /// "Forgot password?" on the sign-in form: carries the typed email over, clears everything else.
    private func forgotPassword() {
        password = ""; confirmPassword = ""; code = ""
        error = nil; info = nil
        reset = .email
    }

    /// Step 1 (and Resend on step 2): request the recovery email. Captcha first — `/recover` is protected.
    private func sendResetCode() {
        let resend = reset == .code
        if resend, Date() < resendAvailableAt { return }
        let mail = (resend ? pendingEmail : email).trimmingCharacters(in: .whitespaces)
        guard Self.isEmail(mail) else { error = L("login_err_invalid_email"); return }
        runWithCaptcha({ await auth.sendPasswordReset(email: mail, captchaToken: $0) }) { result in
            // "Accepted", not "account exists" — the server never reveals which (no enumeration), so the
            // code step opens either way.
            guard result == .success else { handle(result); return }
            pendingEmail = mail
            code = ""
            info = resend ? L("login_code_resent") : nil
            resendAvailableAt = Date().addingTimeInterval(Self.resendCooldown)
            reset = .code
        }
    }

    /// Step 2: verify the recovery code. Success signs the user in — hold the sheet open for step 3.
    private func verifyResetCode() {
        guard code.count == Self.codeLength, !busy else { return }
        let mail = pendingEmail, entered = code
        busy = true; error = nil; info = nil
        auth.holdLoginOpen = true // BEFORE the call: the session flips to signed-in as soon as it returns
        Task {
            let result = await auth.verifyPasswordResetCode(email: mail, code: entered)
            busy = false
            if result == .success {
                code = ""; password = ""; confirmPassword = ""
                reset = .newPassword
                return
            }
            auth.holdLoginOpen = false
            switch result {
            case .tooManyRequests: error = L("login_err_too_many")
            case .networkError: error = L("login_err_network")
            default: error = L("login_err_code_invalid")
            }
        }
    }

    /// Step 3: set the new password on the fresh, just-verified session, then close the sheet.
    private func saveNewPassword() {
        guard !busy else { return }
        guard password.count >= Self.minPassword else { error = L("login_err_password_short", Self.minPassword); return }
        guard password == confirmPassword else { error = L("login_err_password_mismatch"); return }
        let pwd = password
        busy = true; error = nil; info = nil
        focus = nil
        Task {
            let result = await auth.setPassword(pwd)
            busy = false
            switch result {
            // passwordAlreadySet = they chose the password they already had — it IS set, so: done.
            case .success, .passwordAlreadySet:
                info = L("login_reset_done")
                try? await Task.sleep(for: .seconds(1.2)) // let "Password updated" be read before closing
                auth.holdLoginOpen = false
                dismiss()
            // The server rule is stricter than the app's (dashboard changed) — say the rule, not "weak".
            case .weakPassword: error = L("login_err_password_short", Self.minPassword)
            case .tooManyRequests: error = L("login_err_too_many")
            case .networkError: error = L("login_err_network")
            // Still on the fresh session, so they can simply tap Save again.
            default: error = L("login_err_generic")
            }
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8)
            else { error = L("login_err_generic"); return }
            let nonce = appleNonce.raw
            run { await auth.signInWithApple(idToken: token, rawNonce: nonce, fullName: credential.fullName) }
        case .failure(let failure):
            if (failure as? ASAuthorizationError)?.code != .canceled { error = L("login_err_generic") }
        }
    }

    private func handle(_ result: SignInResult, email mail: String? = nil) {
        switch result {
        case .success:
            // The auth listener flips the state and RootView dismisses the sheet.
            break
        case .cancelled:
            break
        case .emailConfirmationRequired:
            startCodeStep(mail ?? email, message: L("login_info_confirm_email"))
        case .emailNotConfirmed:
            startCodeStep(mail ?? email, message: L("login_info_needs_confirm"))
        case .invalidCredentials: error = L("login_err_invalid_credentials")
        case .captchaFailed: error = L("login_err_captcha")
        case .emailAlreadyRegistered: error = L("login_err_email_exists")
        case .passwordAlreadySet: break
        case .weakPassword: error = L("login_err_weak_password")
        case .tooManyRequests: error = L("login_err_too_many")
        case .networkError: error = L("login_err_network")
        case .reauthRequired: error = L("login_err_generic")
        case .error(let message): error = message == "__code__" ? L("login_err_code_invalid") : L("login_err_generic")
        }
    }

    private func startCodeStep(_ mail: String, message: String) {
        pendingEmail = mail.trimmingCharacters(in: .whitespaces)
        code = ""
        info = message
        error = nil
        awaitingCode = true
        resendAvailableAt = Date().addingTimeInterval(Self.resendCooldown)
    }
}
