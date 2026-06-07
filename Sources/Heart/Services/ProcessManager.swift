import Foundation
import Combine
import Darwin
import AppKit
import SwiftTerm

final class ProcessManager: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var statuses: [String: TaskStatus] = [:]

    private var terminalViews: [String: LocalProcessTerminalView] = [:]
    private var pendingRestart: [String: DevTask] = [:]
    private var keyMonitor: Any?

    /// User's interactive-login-shell PATH, snapshotted once. macOS launchd
    /// hands GUI apps a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), so
    /// without this, anything installed by Homebrew, pnpm/Volta/mise/asdf,
    /// or hand-placed in `~/usr/bin` / `~/.local/bin` would show up as
    /// "command not found" even though `zsh -l -i` runs `.zshrc`. Snapshotting
    /// the PATH from a real login+interactive zsh once at startup and
    /// re-injecting it as the spawned process's environment guarantees child
    /// commands see the same `$PATH` the user gets in Terminal.app.
    private lazy var userShellPath: String = Self.snapshotUserShellPath()
    private lazy var spawnEnvironment: [String] = Self.buildSpawnEnvironment(userPath: userShellPath)

    /// Per-task list of open Claude sessions. Lives here (not in ClaudeDetailView's @State)
    /// so the sessions survive sidebar selection changes.
    @Published var claudeSessions: [String: [ClaudeSession]] = [:]
    /// Active session id per task — drives which session's terminal is visible.
    @Published var activeClaudeSession: [String: String] = [:]

    override init() {
        super.init()
        installKeyMonitor()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func status(_ taskId: String) -> TaskStatus {
        statuses[taskId] ?? .stopped
    }

    /// Returns (creating if needed) the persistent terminal view for this task. The view
    /// owns the scrollback buffer + cursor state, so switching selection or restarting
    /// the process keeps prior output visible.
    func terminalView(for taskId: String) -> LocalProcessTerminalView {
        if let view = terminalViews[taskId] {
            return view
        }
        // Start at a generous initial frame so SwiftTerm's processSizeChange
        // computes a sane cols/rows (≈140×42 at 12pt monospace) before the
        // container view lays out. The child process inherits this as its
        // PTY winsize on startProcess, so commands that probe terminal width
        // at spawn time (`claude`, `tput cols`, anything reading $COLUMNS)
        // see a real number instead of the 80×24 fallback — or worse, 0×0
        // when the container is still pre-layout.
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        // SwiftTerm default scrollback is 500 lines — way too small for dev servers that
        // log hundreds of lines per request. 10k is a compromise: deep enough to scroll
        // through long sessions (build logs, test runs, claude conversations) without
        // making SwiftTerm's per-paint allocation grow huge. The earlier 50k setting
        // was suspected of contributing to render lag in Claude Code's dynamic UI.
        view.getTerminal().changeScrollback(10_000)
        terminalViews[taskId] = view
        return view
    }

    private func taskId(for view: LocalProcessTerminalView) -> String? {
        terminalViews.first(where: { $0.value === view })?.key
    }

    /// Intercepts key events when one of our embedded terminals has focus, so we can
    /// emit shortcuts (Shift+Enter, Option+Enter) the way iTerm2 / Apple Terminal would
    /// after `claude /terminal-setup` — needed because SwiftTerm's `keyDown` isn't `open`.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let view = NSApp.keyWindow?.firstResponder as? LocalProcessTerminalView else {
                return event
            }
            // Return / Enter (keyCode 36) and numpad Enter (76).
            if event.keyCode == 36 || event.keyCode == 76 {
                // Shift+Enter — Claude CLI / shell readline interpret "\<CR>" (0x5C 0x0D) as
                // a continued line, while bare CR submits.
                if event.modifierFlags.contains(.shift) {
                    view.process.send(data: ArraySlice([0x5C, 0x0D]))
                    return nil
                }
                // Option+Enter — Meta+Enter (ESC + CR), used by some REPLs for newline.
                if event.modifierFlags.contains(.option) {
                    view.process.send(data: ArraySlice([0x1B, 0x0D]))
                    return nil
                }
            }
            return event
        }
    }

    // MARK: - lifecycle

    func start(_ task: DevTask) {
        // Browser tasks have no command — they exist only to render the in-app
        // browser tab in the detail pane.
        if task.isBrowser { return }
        let view = terminalView(for: task.id)
        if view.process.running {
            return
        }

        statuses[task.id] = .starting
        feed(taskId: task.id, ansi: "\r\n\u{1B}[2m— starting: \(task.command) (cwd: \(task.cwd)) —\u{1B}[0m\r\n")

        let expandedCwd = (task.cwd as NSString).expandingTildeInPath
        // Wrap in a login+interactive zsh so the user's PATH/aliases load (.zprofile + .zshrc).
        // Single-quote the cwd; escape any literal single quotes inside (rare in real paths).
        let escapedCwd = expandedCwd.replacingOccurrences(of: "'", with: "'\\''")
        // Force the PTY's winsize to match what SwiftTerm thinks the terminal
        // is *right now*, before any user command runs. SwiftTerm sets winsize
        // via TIOCSWINSZ during startProcess, but on the very first spawn the
        // container view may still be 0×0 (SwiftUI hasn't laid out yet) so
        // the child sees an absurd size, and tools like `claude` cache that
        // value at startup. The leading `stty` re-stamps a sane size from
        // inside the spawned shell; SwiftTerm's later resize-on-layout still
        // wins because TIOCSWINSZ takes precedence over a one-shot stty.
        let cols = max(80, view.getTerminal().cols)
        let rows = max(24, view.getTerminal().rows)
        let wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; cd '\(escapedCwd)' && \(task.command)"

        // Inject COLUMNS/LINES alongside SwiftTerm's PTY winsize. zsh's TRAPWINCH
        // updates COLUMNS/LINES on SIGWINCH, but for tools that read these once
        // at spawn (some Node CLIs, status-line libs) the initial values matter —
        // without them they fall back to 80×24 and start drawing as if narrow.
        var perTaskEnv = spawnEnvironment
        perTaskEnv.append("COLUMNS=\(cols)")
        perTaskEnv.append("LINES=\(rows)")

        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-i", "-c", wrapped],
            environment: perTaskEnv,
            execName: nil
        )

        scheduleReadinessCheck(for: task)
    }

    // MARK: - Environment snapshot

    /// One-shot snapshot of `$PATH` from a login + interactive zsh. Falls back
    /// to the current process's PATH when something goes wrong so we still
    /// spawn *something* rather than nothing.
    private static func snapshotUserShellPath() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l: source .zprofile / .zlogin.  -i: source .zshrc.
        // `print -rn -- $PATH` is portable, prints raw without newline so we
        // don't have to trim a trailing \n on every platform.
        process.arguments = ["-l", "-i", "-c", "print -rn -- $PATH"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()  // discard
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                NSLog("[ProcessManager] snapshotUserShellPath: %@", path)
                return path
            }
        } catch {
            NSLog("[ProcessManager] snapshotUserShellPath failed: %@", "\(error)")
        }
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Inherit Heart.app's environment but with PATH replaced by the user's
    /// shell PATH. Returned as `["KEY=VALUE", …]` because that's what
    /// LocalProcessTerminalView.startProcess expects.
    ///
    /// We also force `TERM=xterm-256color` and `COLORTERM=truecolor` because
    /// Heart.app is launched by launchd which doesn't set those vars — without
    /// them, CLIs like `claude` probe stdout and start in monochrome mode for
    /// the first few render passes (the splash banner draws white, then later
    /// output picks up colors once the app re-queries terminal caps). Setting
    /// them up front means colors come through from frame zero. LANG follows
    /// SwiftTerm's `getEnvironmentVariables` so UTF-8 glyphs render correctly.
    private static func buildSpawnEnvironment(userPath: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = userPath
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        // Hint to terminal-aware CLIs that Heart isn't iTerm / VS Code so they
        // don't enable features SwiftTerm can't handle gracefully (most
        // notably Claude Code's alt-screen "flicker-free" renderer, which
        // emits modern escape sequences SwiftTerm parses poorly and produces
        // the "every character on its own line" garbling — bug we couldn't
        // root-cause via the earlier winsize fix). Explicit `=0` is a stronger
        // signal than just absence, since Claude Code's default has flipped
        // before across versions.
        env["TERM_PROGRAM"] = "Heart"
        env["CLAUDE_CODE_NO_FLICKER"] = "0"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Graceful stop: SIGINT (like Ctrl+C) → 3s SIGTERM → 3s SIGKILL.
    /// For tasks Heart didn't spawn (foreign services detected via
    /// `scanForExternalServices`), fall back to `killPort` so the user can still
    /// take a port back even though Heart isn't holding the process handle.
    func stop(_ task: DevTask) {
        if let view = terminalViews[task.id], view.process.running {
            statuses[task.id] = .stopping
            let pid = view.process.shellPid

            // PTY line discipline: writing 0x03 to master delivers SIGINT to the foreground process group.
            view.process.send(data: ArraySlice([0x03]))

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self,
                      let v = self.terminalViews[task.id],
                      v.process.running else { return }
                kill(pid, SIGTERM)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self,
                          let v = self.terminalViews[task.id],
                          v.process.running else { return }
                    kill(pid, SIGKILL)
                }
            }
            return
        }

        // External service — Heart didn't spawn it but the UI shows it as running
        // because the port is bound. Free the port and reflect the new state.
        if statuses[task.id] == .externalRunning,
           let port = task.port,
           Self.isPortBound(port) {
            statuses[task.id] = .stopping
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.killPort(port, for: task.id)
                DispatchQueue.main.async {
                    self?.statuses[task.id] = .stopped
                }
            }
        }
    }

    func restart(_ task: DevTask) {
        if let view = terminalViews[task.id], view.process.running {
            pendingRestart[task.id] = task
            stop(task)
        } else {
            start(task)
        }
    }

    func toggle(_ task: DevTask) {
        if terminalViews[task.id]?.process.running == true {
            stop(task)
        } else {
            start(task)
        }
    }

    func startAll(_ tasks: [DevTask]) {
        for task in tasks { start(task) }
    }

    func stopAll(_ tasks: [DevTask]) {
        for task in tasks { stop(task) }
    }

    // MARK: - input / output helpers

    /// Forward bytes typed in the embedded terminal to the running process's stdin.
    /// LocalProcessTerminalView wires keyboard → PTY automatically; this is for programmatic input.
    func sendInput(_ taskId: String, data: Data) {
        guard let view = terminalViews[taskId], view.process.running else { return }
        view.process.send(data: ArraySlice(data))
    }

    /// Inject a banner/notification into the terminal scrollback (renders ANSI colors).
    func feed(taskId: String, ansi: String) {
        let view = terminalView(for: taskId)
        view.feed(text: ansi)
    }

    func clearOutput(_ taskId: String) {
        guard let view = terminalViews[taskId] else { return }
        // RIS (\u001Bc) — full reset: clears screen, scrollback, modes, charset.
        view.feed(text: "\u{1B}c")
    }

    /// Scan tasks with a `port` and flag them as `.externalRunning` if the port
    /// is already bound by a process Heart didn't spawn — e.g. `redis-server`
    /// started outside Heart. Existing statuses (Heart-owned running tasks,
    /// in-flight transitions) are left alone; only `.stopped` / unset entries
    /// get flipped. The distinct `.externalRunning` state lets the detail view
    /// explain why the terminal is empty (we don't own the PTY) and offer a
    /// "Run in Heart" handoff.
    func scanForExternalServices(_ tasks: [DevTask]) {
        for task in tasks {
            guard let port = task.port else { continue }
            if let view = terminalViews[task.id], view.process.running { continue }
            switch statuses[task.id] {
            case .none, .stopped:
                if Self.isPortBound(port) {
                    statuses[task.id] = .externalRunning
                }
            default:
                break
            }
        }
    }

    /// Hard-kill any running process for this id and drop the cached terminal view.
    /// Used when closing an ephemeral session tab (e.g. Claude shortcut sessions) — we want
    /// the session gone immediately, no graceful chain.
    func removeTerminal(taskId: String) {
        if let view = terminalViews[taskId], view.process.running {
            kill(view.process.shellPid, SIGKILL)
        }
        terminalViews.removeValue(forKey: taskId)
        statuses.removeValue(forKey: taskId)
        pendingRestart.removeValue(forKey: taskId)
    }

    // MARK: - Claude sessions

    func sessions(for taskId: String) -> [ClaudeSession] {
        claudeSessions[taskId] ?? []
    }

    func activeSession(for taskId: String) -> String? {
        let list = sessions(for: taskId)
        if let recorded = activeClaudeSession[taskId], list.contains(where: { $0.id == recorded }) {
            return recorded
        }
        return list.first?.id
    }

    /// Spawn a new Claude session for this shortcut task and return its id.
    @discardableResult
    func addSession(for task: DevTask) -> String {
        let sid = "claude-session-\(task.id)-\(UUID().uuidString.prefix(8))"
        let session = ClaudeSession(id: sid, name: nil)
        var list = claudeSessions[task.id] ?? []
        list.append(session)
        claudeSessions[task.id] = list
        activeClaudeSession[task.id] = sid

        let shadow = DevTask(id: sid,
                             name: task.name,
                             command: task.command,
                             cwd: task.cwd)
        start(shadow)
        return sid
    }

    /// Inputs for `resumeSession`. Value-typed so future additions (continue
    /// mode, PR-linked resume, custom permission mode, etc.) don't break
    /// existing call sites.
    struct ResumeOptions {
        let sessionId: UUID
        let forkSession: Bool
        let displayName: String?
        let initialPrompt: String?
    }

    /// Open a new Claude session that resumes an existing conversation by
    /// UUID. Mirrors `addSession` but the shadow task's command is built via
    /// `ClaudeSessionService.buildResumeCommand` so flags like `--fork-session`
    /// and `-n <name>` are escaped safely.
    @discardableResult
    func resumeSession(for task: DevTask, options: ResumeOptions) -> String {
        let shortId = String(options.sessionId.uuidString.prefix(8))
        // Heart-internal id; dedup if the user resumes the same session twice
        // in the same task without closing the first instance.
        var sid = "claude-resume-\(task.id)-\(shortId)"
        var bump = 2
        var list = claudeSessions[task.id] ?? []
        while list.contains(where: { $0.id == sid }) {
            sid = "claude-resume-\(task.id)-\(shortId)-\(bump)"
            bump += 1
        }
        let trimmedDisplay = options.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionLabel = trimmedDisplay.isEmpty ? "↻ \(shortId)" : trimmedDisplay
        list.append(ClaudeSession(id: sid, name: sessionLabel))
        claudeSessions[task.id] = list
        activeClaudeSession[task.id] = sid

        let command = ClaudeSessionService.buildResumeCommand(
            sessionId: options.sessionId,
            forkSession: options.forkSession,
            displayName: trimmedDisplay.isEmpty ? nil : trimmedDisplay,
            initialPrompt: options.initialPrompt
        )
        let shadow = DevTask(id: sid,
                             name: task.name,
                             command: command,
                             cwd: task.cwd)
        start(shadow)
        return sid
    }

    func removeSession(taskId: String, sessionId: String) {
        var list = claudeSessions[taskId] ?? []
        list.removeAll { $0.id == sessionId }
        claudeSessions[taskId] = list
        if activeClaudeSession[taskId] == sessionId {
            activeClaudeSession[taskId] = list.last?.id
        }
        removeTerminal(taskId: sessionId)
    }

    func setActiveSession(taskId: String, sessionId: String) {
        activeClaudeSession[taskId] = sessionId
    }

    func renameSession(taskId: String, sessionId: String, name: String?) {
        var list = claudeSessions[taskId] ?? []
        guard let idx = list.firstIndex(where: { $0.id == sessionId }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        list[idx].name = (trimmed?.isEmpty == false) ? trimmed : nil
        claudeSessions[taskId] = list
    }

    // MARK: - readiness

    private func scheduleReadinessCheck(for task: DevTask) {
        let started = Date()
        let portTimeout: TimeInterval = 30
        let noPortGrace: TimeInterval = 1.5
        let pollInterval: TimeInterval = 0.3
        let taskId = task.id

        func tick() {
            guard let view = self.terminalViews[taskId], view.process.running else { return }
            guard self.statuses[taskId] == .starting else { return }

            if let port = task.port {
                if Self.isPortBound(port) {
                    self.statuses[taskId] = .running
                    self.feed(taskId: taskId, ansi: "\u{1B}[32m[ready]\u{1B}[0m listening on :\(port)\r\n")
                    return
                }
                if Date().timeIntervalSince(started) > portTimeout {
                    self.statuses[taskId] = .running
                    self.feed(taskId: taskId, ansi: "\u{1B}[33m[ready]\u{1B}[0m timeout waiting for :\(port) — marking running\r\n")
                    return
                }
            } else {
                if Date().timeIntervalSince(started) >= noPortGrace {
                    self.statuses[taskId] = .running
                    return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { tick() }
    }

    private static func isPortBound(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.connect(sock, sptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - port killing

    /// Kills any process listening on the given TCP port (best-effort: `lsof | xargs kill -9`).
    func killPort(_ port: Int, for taskId: String? = nil) {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "PIDS=$(lsof -ti tcp:\(port) 2>/dev/null); if [ -n \"$PIDS\" ]; then echo \"Killing on :\(port): $PIDS\"; echo $PIDS | xargs kill -9; else echo \"No process on :\(port)\"; fi"]
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if let taskId {
                feed(taskId: taskId, ansi: "\r\n\u{1B}[33m[kill-port \(port)]\u{1B}[0m \(output)")
            }
        } catch {
            if let taskId {
                feed(taskId: taskId, ansi: "\r\n\u{1B}[31m[kill-port \(port)] error\u{1B}[0m: \(error.localizedDescription)\r\n")
            }
        }
    }

    // MARK: - shutdown

    /// Synchronously stops every running process before the app exits, so dev servers
    /// (`php artisan serve`, `npm run dev`, …) don't leave their listening port pinned
    /// after Heart quits. Strategy:
    ///   1) Ctrl+C via PTY (SIGINT to the foreground process group),
    ///   2) `killpg(SIGTERM)` to the whole group — covers shell children that wouldn't
    ///      otherwise receive a signal when the parent zsh dies.
    ///   3) Up to 2s shared wait so all tasks drain in parallel.
    ///   4) `killpg(SIGKILL)` for stragglers.
    func terminateAllSync() {
        let running = terminalViews.values.filter { $0.process.running }
        guard !running.isEmpty else { return }

        for view in running {
            let pid = view.process.shellPid
            view.process.send(data: ArraySlice([0x03]))   // PTY Ctrl+C → SIGINT to fg pgrp
            _ = killpg(pid, SIGTERM)                      // SIGTERM to the entire pgrp
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if running.allSatisfy({ !$0.process.running }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }

        for view in running where view.process.running {
            _ = killpg(view.process.shellPid, SIGKILL)
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // LocalProcessTerminalView already calls TIOCSWINSZ on its embedded LocalProcess.
        // Nothing to do here — but we still must implement it for protocol conformance.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Ignored — we show our own task name.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Ignored — task already pins cwd.
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let view = source as? LocalProcessTerminalView,
              let taskId = taskId(for: view) else { return }
        let code = exitCode ?? -1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if code == 0 {
                self.statuses[taskId] = .stopped
            } else {
                self.statuses[taskId] = .crashed(exitCode: code)
            }
            self.feed(taskId: taskId, ansi: "\r\n\u{1B}[2m— exited (code \(code)) —\u{1B}[0m\r\n")

            if let pending = self.pendingRestart.removeValue(forKey: taskId) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.start(pending)
                }
            }
        }
    }
}
