import AuthenticationServices
import SwiftUI

/// The on-demand sign-in sheet: Apple / Google, or email + password with a 6-digit email-confirmation
/// step. Every email call first acquires a Turnstile token (see `CaptchaGate`).
struct LoginView: View {
    private enum Mode { case signIn, signUp }

    private static let minPassword = 6
    private static let codeLength = 6
    private static let resendCooldown: TimeInterval = 60

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AuthService.self) private var auth
    @Environment(Connectivity.self) private var connectivity

    @State private var captcha = CaptchaGate()
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var busy = false
    @State private var error: String?
    @State private var info: String?

    // OTP step
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
                    if awaitingCode { codeStep } else { credentialsStep }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .bwScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if awaitingCode {
                        Button(L("login_back")) { awaitingCode = false; code = ""; error = nil; info = nil }
                    } else {
                        Button(L("action_close")) { dismiss() }
                    }
                }
            }
            .overlay { CaptchaHost(gate: captcha) }
        }
        .interactiveDismissDisabled(busy)
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
                SecureField(L("login_password"), text: $password)
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

        if let error { notice(error, color: Bw.error) }
        if let info { notice(info, color: Bw.success) }

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
    }

    // MARK: Step 2 — email confirmation code

    @ViewBuilder private var codeStep: some View {
        Image(systemName: "envelope.badge").font(.system(size: 44)).foregroundStyle(Bw.link2).padding(.top, 12)
        Text(L("login_confirm_title")).font(.title2.weight(.bold))
        Text(L("login_confirm_sent", pendingEmail)).font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center)

        field {
            TextField(L("login_code_hint"), text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit().weight(.semibold)).multilineTextAlignment(.center).tracking(6)
                .focused($focus, equals: .code)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(Self.codeLength))
                    if code.count == Self.codeLength { verifyCode() }
                }
        }
        .onAppear { focus = .code }

        if let error { notice(error, color: Bw.error) }
        if let info { notice(info, color: Bw.success) }

        Button(action: verifyCode) {
            if busy { ProgressView().tint(Bw.onYellow) } else { Text(L("login_verify_action")) }
        }
        .buttonStyle(.bwPrimary)
        .disabled(busy || offline || code.count != Self.codeLength)

        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
            HStack(spacing: 2) {
                Text(L("login_resend_prompt")).foregroundStyle(Bw.textMuted)
                if remaining > 0 {
                    Text(L("login_resend_in", remaining)).foregroundStyle(Bw.textFaint)
                } else {
                    Button(L("login_resend_code"), action: resendCode).fontWeight(.semibold).foregroundStyle(Bw.link).disabled(busy || offline)
                }
            }
            .font(.subheadline)
        }
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

    private func submitEmail() {
        let mail = email.trimmingCharacters(in: .whitespaces)
        guard mail.contains("@"), mail.contains("."), !mail.contains(" ") else { error = L("login_err_invalid_email"); return }
        guard password.count >= Self.minPassword else { error = L("login_err_password_short", Self.minPassword); return }
        if mode == .signUp {
            guard password == confirmPassword else { error = L("login_err_password_mismatch"); return }
            let lang = Locale.current.language.languageCode?.identifier == "vi" ? "vi" : "en"
            let pwd = password
            runWithCaptcha({ await auth.signUp(email: mail, password: pwd, lang: lang, captchaToken: $0) }) { result in
                if result == .emailConfirmationRequired { pendingPassword = pwd }
                handle(result, email: mail)
            }
        } else {
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
            return result == .success ? .success : .error("__code__")
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

    private func forgotPassword() {
        let mail = email.trimmingCharacters(in: .whitespaces)
        guard mail.contains("@"), mail.contains(".") else { error = L("login_err_invalid_email"); return }
        runWithCaptcha({ await auth.sendPasswordReset(email: mail, captchaToken: $0) }) { result in
            if result == .success { info = L("login_reset_sent") } else { handle(result) }
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
