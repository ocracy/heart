import SwiftUI
import AppKit
import WebKit

/// In-app browser per task. Holds a persistent `WKWebView` (model owns it) so navigation
/// state survives Terminal↔Browser tab switches. Mobile toggle swaps the user-agent and
/// clamps the viewport to 390pt centered. "Open in Chrome" hands the current URL to the
/// system Chrome.app (or default browser if Chrome isn't installed).
struct BrowserView: View {
    @StateObject private var model: BrowserModel

    init(url: String) {
        _model = StateObject(wrappedValue: BrowserModel(initialURL: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            webArea
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

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

final class BrowserModel: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var addressBar: String
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var isMobile: Bool = false

    private var observations: [NSKeyValueObservation] = []

    private static let mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    init(initialURL: String) {
        let config = WKWebViewConfiguration()
        // Persistent data store: cookies, localStorage retained across launches (per WebKit defaults).
        config.websiteDataStore = .default()
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                 configuration: config)
        self.addressBar = initialURL
        super.init()

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

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    func reload() {
        if webView.isLoading {
            webView.stopLoading()
            return
        }
        // `WKWebView.reload()` is a no-op if the view never finished its initial load (which
        // happens with localhost dev servers that briefly 502 before catching up). Issuing a
        // fresh `load(URLRequest)` on the current URL — falling back to the address bar —
        // always re-fires the request.
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
}
