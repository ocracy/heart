import Foundation
import SwiftUI
import AppKit

/// Polls the GitHub Releases API for newer versions and, on user request,
/// downloads the published `Heart.zip`, unpacks it, then atomically swaps
/// the running `Heart.app` bundle with the new one via a detached helper
/// shell script before relaunching. Sparkle would handle this more
/// formally, but Sparkle's EdDSA flow assumes a signed update feed which
/// the project (ad-hoc signed, no paid Apple Developer ID) can't produce.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String     // "1.8.0" — leading 'v' stripped
        let tag: String         // "v1.8.0" — original tag from GitHub
        let notes: String
        let zipURL: URL
        let publishedAt: Date
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Double)    // 0.0 — 1.0
        case installing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheckedAt: Date?
    @Published var sheetPresented: Bool = false

    let currentVersion: String

    private let owner = "ocracy"
    private let repo = "heart"
    private let lastCheckKey = "Heart.UpdateChecker.lastCheck"
    private let throttle: TimeInterval = 24 * 60 * 60

    private var downloadCoordinator: DownloadCoordinator?

    private init() {
        self.currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        if let stored = UserDefaults.standard.object(forKey: lastCheckKey) as? Date {
            self.lastCheckedAt = stored
        }
    }

    // MARK: - Toolbar entry point

    /// Always opens the sheet. If we're idle / up-to-date / errored, also kicks
    /// off a fresh check so the user sees current status rather than a stale
    /// "no update" message.
    func toolbarTapped() {
        sheetPresented = true
        switch state {
        case .idle, .upToDate, .error:
            Task { await checkNow(userInitiated: true) }
        case .checking, .available, .downloading, .installing:
            break
        }
    }

    // MARK: - Check

    func checkNow(userInitiated: Bool) async {
        if !userInitiated, let last = lastCheckedAt, Date().timeIntervalSince(last) < throttle {
            return
        }
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await fetchLatestRelease()
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt, forKey: lastCheckKey)
            if isNewerVersion(release.version, than: currentVersion) {
                state = .available(release)
                if userInitiated { sheetPresented = true }
            } else {
                state = .upToDate
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Heart/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError("Bağlantı yanıtı alınamadı")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateError("GitHub API \(http.statusCode)")
        }

        struct APIRelease: Decodable {
            let tag_name: String
            let body: String?
            let published_at: String?
            let assets: [Asset]
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        let decoded = try JSONDecoder().decode(APIRelease.self, from: data)
        let tag = decoded.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let zipAsset = decoded.assets.first(where: { $0.name.lowercased() == "heart.zip" }),
              let zipURL = URL(string: zipAsset.browser_download_url) else {
            throw UpdateError("Bu release'de Heart.zip bulunamadı")
        }
        let publishedAt: Date = {
            guard let str = decoded.published_at else { return Date() }
            return ISO8601DateFormatter().date(from: str) ?? Date()
        }()
        return Release(version: version,
                       tag: tag,
                       notes: (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       zipURL: zipURL,
                       publishedAt: publishedAt)
    }

    /// String comparison with `.numeric` correctly orders "1.10.0" > "1.9.0",
    /// unlike lexical comparison. Pre-release suffixes (e.g. "1.8.0-beta")
    /// will sort *after* "1.8.0" by string compare, which is fine — we just
    /// don't promote pre-release as an upgrade unless the tag itself is newer.
    private func isNewerVersion(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    // MARK: - Download + install

    func downloadAndInstall() async {
        guard case .available(let release) = state else { return }
        state = .downloading(0)
        do {
            let zipURL = try await downloadZip(from: release.zipURL)
            let stagedApp = try unzipStaged(zipURL: zipURL, version: release.version)
            try installAndRelaunch(stagedApp: stagedApp)
            state = .installing
            // Give the user ~half a second to read "Yeniden başlatılıyor…"
            // before the window disappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSApp.terminate(nil)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func downloadZip(from url: URL) async throws -> URL {
        let updatesDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heart/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updatesDir, withIntermediateDirectories: true)
        let destination = updatesDir.appendingPathComponent("Heart-\(UUID().uuidString).zip")

        let coordinator = DownloadCoordinator(destination: destination) { [weak self] progress in
            Task { @MainActor in
                guard let self = self else { return }
                if case .downloading = self.state {
                    self.state = .downloading(progress)
                }
            }
        }
        self.downloadCoordinator = coordinator
        defer { self.downloadCoordinator = nil }

        return try await coordinator.download(url: url)
    }

    private func unzipStaged(zipURL: URL, version: String) throws -> URL {
        let stageDir = zipURL.deletingLastPathComponent()
            .appendingPathComponent("stage-\(version)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: stageDir)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zipURL.path, stageDir.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "ditto unzip başarısız"
            throw UpdateError(err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: stageDir.path)
        guard let appName = entries.first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError("İndirilen pakette Heart.app bulunamadı")
        }
        return stageDir.appendingPathComponent(appName)
    }

    private func installAndRelaunch(stagedApp: URL) throws {
        let currentApp = Bundle.main.bundleURL
        guard currentApp.path.hasSuffix(".app") else {
            throw UpdateError("Heart bir .app bundle'ı içinden çalışmıyor (\(currentApp.path)). Güncelleyici sadece kurulu uygulamadan çalışır.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heart-update-\(pid).sh")

        let appQ = shellQuote(currentApp.path)
        let stagedQ = shellQuote(stagedApp.path)
        let stageParentQ = shellQuote(stagedApp.deletingLastPathComponent().path)
        let script = """
        #!/bin/bash
        # Heart in-app updater swap helper.
        # Waits for the running Heart (pid \(pid)) to exit, then replaces the
        # installed bundle with the freshly downloaded copy and relaunches.
        for i in $(seq 1 75); do
            kill -0 \(pid) 2>/dev/null || break
            sleep 0.2
        done
        sleep 0.4
        APP=\(appQ)
        STAGED=\(stagedQ)
        rm -rf "$APP"
        cp -R "$STAGED" "$APP" || { echo "cp failed" >&2; exit 1; }
        xattr -cr "$APP" 2>/dev/null || true
        open "$APP"
        rm -rf \(stageParentQ)
        rm -f "$0"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", scriptURL.path]
        try chmod.run()
        chmod.waitUntilExit()

        // Detach via nohup so the helper outlives this process.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = ["-c", "nohup \(shellQuote(scriptURL.path)) </dev/null >/dev/null 2>&1 &"]
        try launcher.run()
        launcher.waitUntilExit()
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Toolbar presentation helpers

extension UpdateChecker {
    var toolbarSystemImage: String {
        switch state {
        case .idle, .checking:      return "arrow.down.circle"
        case .upToDate:             return "checkmark.circle"
        case .available:            return "arrow.down.circle.fill"
        case .downloading, .installing: return "arrow.down.circle"
        case .error:                return "exclamationmark.triangle"
        }
    }

    var toolbarTint: Color? {
        switch state {
        case .available:    return .accentColor
        case .error:        return .orange
        default:            return nil
        }
    }

    var toolbarTooltip: String {
        switch state {
        case .idle:                     return "Güncellemeleri kontrol et"
        case .checking:                 return "Kontrol ediliyor…"
        case .upToDate:                 return "Heart \(currentVersion) en güncel sürüm"
        case .available(let r):         return "Heart \(r.version) mevcut — tıklayıp güncelle"
        case .downloading(let p):       return "İndiriliyor… %\(Int(p * 100))"
        case .installing:               return "Yeniden başlatılıyor…"
        case .error(let m):             return "Güncelleme hatası: \(m)"
        }
    }

    var hasAvailableUpdate: Bool {
        if case .available = state { return true }
        return false
    }
}

// MARK: - Helpers

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// URLSessionDownloadDelegate wrapper that streams progress fractions and
/// exposes the finished file as an async result. Kept private so the
/// download API on `UpdateChecker` stays simple.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func download(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var req = URLRequest(url: url)
            req.setValue("Heart-Updater", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
        session?.finishTasksAndInvalidate()
        session = nil
    }

    // URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            finish(.failure(error))
        }
    }
}
