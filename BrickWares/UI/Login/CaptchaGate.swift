import Observation
import SwiftUI
import WebKit

enum CaptchaOutcome: Equatable {
    /// No site key configured (local stack) → send no token.
    case disabled
    case token(String)
    case failed
}

/// Cloudflare Turnstile gate for the email auth flows (prod enforces a captcha token on sign-up,
/// password sign-in, resend and recover; ID-token sign-in, token refresh and OTP verify are exempt).
///
/// `acquire()` activates a hidden web view that loads the app's own captcha page. Turnstile normally
/// scores invisibly and hands a token straight back; only when Cloudflare wants interaction is the
/// widget revealed as a card. Tokens are single-use and short-lived, so one is acquired per call.
@MainActor
@Observable
final class CaptchaGate {
    private(set) var isActive = false
    private(set) var isInteractive = false
    /// Bumped per acquisition so the web view reloads fresh.
    private(set) var nonce = 0

    @ObservationIgnored private var continuation: CheckedContinuation<CaptchaOutcome, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    var siteKey: String { AppConfig.turnstileSiteKey }

    func acquire() async -> CaptchaOutcome {
        guard !siteKey.isEmpty else { return .disabled }
        finish(.failed) // a still-pending acquisition is superseded
        nonce += 1
        isInteractive = false
        isActive = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                if !Task.isCancelled { self?.finish(.failed) }
            }
        }
    }

    func onToken(_ token: String) { finish(token.isEmpty ? .failed : .token(token)) }
    func onError(_: String) { finish(.failed) }
    func onInteractive() { isInteractive = true }
    /// Tapping the scrim dismisses an interactive challenge.
    func cancel() { finish(.failed) }

    private func finish(_ outcome: CaptchaOutcome) {
        timeout?.cancel(); timeout = nil
        isActive = false
        isInteractive = false
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// Hosts the (normally invisible) Turnstile web view; place it as the top overlay of the login UI.
struct CaptchaHost: View {
    let gate: CaptchaGate
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if gate.isActive {
            GeometryReader { geo in
                // Narrower than the 300×65 "normal" widget → ask the page for the 150×140 "compact" one.
                let compact = geo.size.width - 48 < 300
                ZStack {
                    if gate.isInteractive {
                        Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { gate.cancel() }
                    }
                    VStack(spacing: 12) {
                        if gate.isInteractive { Text(L("login_captcha_title")).font(.headline) }
                        TurnstileWebView(gate: gate, url: pageURL(compact: compact))
                            .frame(width: compact ? 160 : 304, height: compact ? 148 : 72)
                            .id("\(gate.nonce)-\(compact)")
                    }
                    .padding(gate.isInteractive ? 18 : 0)
                    .background(gate.isInteractive ? AnyShapeStyle(Bw.card) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 16))
                    // Invisible (but laid out, so the widget can run) until Cloudflare asks for interaction.
                    .opacity(gate.isInteractive ? 1 : 0.01)
                    .allowsHitTesting(gate.isInteractive)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .animation(.snappy, value: gate.isInteractive)
        }
    }

    private func pageURL(compact: Bool) -> URL {
        var components = URLComponents(url: AppConfig.captchaPageURL, resolvingAgainstBaseURL: false)!
        let lang = Locale.current.language.languageCode?.identifier == "vi" ? "vi" : "en"
        components.queryItems = [
            .init(name: "sitekey", value: gate.siteKey),
            .init(name: "lang", value: lang),
            .init(name: "theme", value: colorScheme == .dark ? "dark" : "light"),
            .init(name: "size", value: compact ? "compact" : "normal"),
        ]
        return components.url!
    }
}

private struct TurnstileWebView: UIViewRepresentable {
    let gate: CaptchaGate
    let url: URL

    private static let handlerName = "bwCaptcha"

    /// The hosted page talks to a global `BrickWaresCaptcha` object (Android injects it through
    /// addJavascriptInterface). This shim provides the same object on iOS, forwarding to WebKit's
    /// message handler — so the page needs no iOS-specific changes.
    private static let bridgeShim = """
    window.BrickWaresCaptcha = {
      onToken: function (t) { window.webkit.messageHandlers.\(handlerName).postMessage({ m: 'token', a: String(t || '') }); },
      onError: function (c) { window.webkit.messageHandlers.\(handlerName).postMessage({ m: 'error', a: String(c || '') }); },
      onInteractive: function () { window.webkit.messageHandlers.\(handlerName).postMessage({ m: 'interactive', a: '' }); }
    };
    """

    func makeCoordinator() -> Coordinator { Coordinator(gate: gate) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        config.userContentController.add(context.coordinator, name: Self.handlerName)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    static func dismantleUIView(_ web: WKWebView, coordinator _: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let gate: CaptchaGate
        init(gate: CaptchaGate) { self.gate = gate }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: String], let method = body["m"] else { return }
            let arg = body["a"] ?? ""
            Task { @MainActor [gate] in
                switch method {
                case "token": gate.onToken(arg)
                case "error": gate.onError(arg)
                case "interactive": gate.onInteractive()
                default: break
                }
            }
        }

        /// Main-frame navigation is restricted to the captcha page + Cloudflare's challenge host.
        func webView(
            _: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard action.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }
            let url = action.request.url
            let allowed = url?.scheme == "https" && AppConfig.captchaAllowedHosts.contains(url?.host ?? "")
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) { fail(error) }

        func webView(
            _: WKWebView, decidePolicyFor response: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                Task { @MainActor [gate] in gate.onError("http-\(http.statusCode)") }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        private func fail(_ error: Error) {
            // A cancelled load (our own policy decision / view teardown) is not a captcha failure.
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            Task { @MainActor [gate] in gate.onError("load-failed") }
        }
    }
}
