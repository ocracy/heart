import SwiftUI
import AppKit
import WebKit

/// In-app browser per task. The persistent `WKWebView` lives in BrowserModel, which is
/// cached per task by `BrowserManager` — so cookies, localStorage, navigation history,
/// scroll position, and granted camera/microphone permissions survive task switches.
/// Mobile toggle swaps the user-agent and clamps the viewport to 390pt centered.
/// "Open in Chrome" hands the current URL to the system Chrome.app (or default browser).
struct BrowserView: View {
    let url: String
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            webArea
        }
        // Task edited → new URL prop → navigate the existing WKWebView instead of
        // tearing it down. Keeps cookies, history, scroll position; just swaps the page.
        .onChange(of: url) { newURL in
            model.navigateIfChanged(newURL)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            navIcon(systemName: "chevron.left",
                    enabled: model.canGoBack,
                    help: "Back") {
                model.goBack()
            }

            navIcon(systemName: "chevron.right",
                    enabled: model.canGoForward,
                    help: "Forward") {
                model.goForward()
            }

            navIcon(systemName: model.isLoading ? "xmark" : "arrow.clockwise",
                    enabled: true,
                    help: model.isLoading ? "Stop loading" : "Reload page",
                    tint: model.isLoading ? .orange : .accentColor) {
                model.reload()
            }

            TextField("URL", text: $model.addressBar)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit { model.navigate(model.addressBar) }

            navIcon(systemName: model.isMobile ? "iphone" : "laptopcomputer",
                    enabled: true,
                    help: model.isMobile ? "Switch to desktop view" : "Switch to mobile view",
                    tint: model.isMobile ? .accentColor : .secondary) {
                model.setMobile(!model.isMobile)
            }

            Button {
                model.openInChrome()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Chrome")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5)
                )
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Open current URL in Google Chrome")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func navIcon(systemName: String,
                         enabled: Bool,
                         help: String,
                         tint: Color = .primary,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.4))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var webArea: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if model.isMobile { Spacer(minLength: 0) }
                WebViewHost(webView: model.webView)
                    .frame(width: model.isMobile ? 390 : geo.size.width)
                if model.isMobile { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

/// Container around the per-task `WKWebView` so SwiftUI can swap a different
/// task's web view in without throwing the previous one away. Mirrors the
/// terminal-container pattern in OutputView: if we returned the WKWebView
/// directly from makeNSView, switching tasks would leave the **old** task's
/// page on screen — updateNSView gets the new prop but has no chance to swap
/// the underlying NSView.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WebContainerView {
        let container = WebContainerView()
        container.autoresizingMask = [.width, .height]
        container.attach(webView)
        return container
    }
    func updateNSView(_ container: WebContainerView, context: Context) {
        container.attach(webView)
    }
}

final class WebContainerView: NSView {
    private weak var currentWebView: WKWebView?

    func attach(_ wv: WKWebView) {
        if currentWebView === wv { return }
        currentWebView?.removeFromSuperview()
        wv.removeFromSuperview()
        wv.frame = bounds
        wv.autoresizingMask = [.width, .height]
        addSubview(wv)
        currentWebView = wv
    }
}

final class BrowserModel: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    @Published var addressBar: String
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var isMobile: Bool = false

    /// Tracks the most recent URL set via the task's `url` field, so a subsequent
    /// no-op task switch (same URL) doesn't trigger an unwanted reload.
    private var lastTaskURL: String

    private var observations: [NSKeyValueObservation] = []

    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init(initialURL: String) {
        let config = WKWebViewConfiguration()
        // Persistent data store — cookies, localStorage, IndexedDB survive launches.
        config.websiteDataStore = .default()
        // Modern web feature support: inline video, autoplay-friendly, JS-driven media.
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // Enable developer extras (right-click → Inspect Element) — useful for the
        // local dev-server context Heart is designed around.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if #available(macOS 13.3, *) {
            config.preferences.isElementFullscreenEnabled = true
        }

        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                 configuration: config)
        // Match what the system Safari sends so SaaS sign-ins don't refuse the UA.
        self.webView.customUserAgent = nil
        self.webView.allowsBackForwardNavigationGestures = true
        self.webView.allowsMagnification = true

        self.addressBar = initialURL
        self.lastTaskURL = initialURL
        super.init()

        // Delegates AFTER super.init — needed to grant getUserMedia() prompts and to
        // surface JS dialogs / navigation events later if we add support.
        self.webView.uiDelegate = self
        self.webView.navigationDelegate = self

        observations.append(webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async {
                if let url = view.url?.absoluteString { self?.addressBar = url }
            }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.isLoading = view.isLoading }
        })

        navigate(initialURL)
    }

    func navigate(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") {
            s = "http://" + s
        }
        guard let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Used when the task's `url` field changes — navigate only if it's actually
    /// different from the last task-driven URL, so picking the same task again
    /// (or selection-flicker) doesn't blow away the user's current page state.
    func navigateIfChanged(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s != lastTaskURL else { return }
        lastTaskURL = s
        navigate(s)
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    func reload() {
        if webView.isLoading {
            webView.stopLoading()
            return
        }
        // `WKWebView.reload()` is a no-op if the view never finished its initial load
        // (which happens with localhost dev servers that briefly 502 before catching
        // up). Issuing a fresh `load(URLRequest)` on the current URL — falling back to
        // the address bar — always re-fires the request.
        if let url = webView.url {
            webView.load(URLRequest(url: url))
        } else {
            navigate(addressBar)
        }
    }

    func setMobile(_ on: Bool) {
        isMobile = on
        webView.customUserAgent = on ? Self.mobileUA : nil
        // UA is only applied on next request — refresh to reflect the change.
        if let url = webView.url {
            webView.load(URLRequest(url: url))
        } else {
            navigate(addressBar)
        }
    }

    /// Open the current URL in Google Chrome (external). Falls back to the default browser
    /// if Chrome isn't installed at the standard location.
    func openInChrome() {
        let candidate = webView.url?.absoluteString ?? addressBar
        let resolved: URL? = {
            if candidate.contains("://") { return URL(string: candidate) }
            return URL(string: "http://" + candidate)
        }()
        guard let url = resolved else { return }

        let chromePath = "/Applications/Google Chrome.app"
        if FileManager.default.fileExists(atPath: chromePath) {
            let chromeURL = URL(fileURLWithPath: chromePath)
            NSWorkspace.shared.open([url],
                                    withApplicationAt: chromeURL,
                                    configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - WKUIDelegate

    /// Auto-grant getUserMedia() prompts (camera / microphone). Without this,
    /// `navigator.mediaDevices.getUserMedia()` resolves with NotAllowedError because
    /// WKWebView's default decision is to deny. Info.plist must also declare
    /// NSCameraUsageDescription and NSMicrophoneUsageDescription — see build.sh / dist.sh.
    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    /// Open links that try to spawn a new window (target=_blank, window.open) in the
    /// same webview instead of silently dropping them — the default behavior is to
    /// return nil, which makes those links appear broken to the user.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
