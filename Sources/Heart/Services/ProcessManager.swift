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
    private var scrollMonitor: Any?
    private var lastScrollSend = Date.distantPast

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

    /// Live Claude attention state per *spawned* task id (for Claude sessions
    /// this is the shadow session id, not the parent shortcut id). Fed by the
    /// hook bridge file watcher. UI reads it via `attentionFor`.
    @Published var attention: [String: ClaudeAttention] = [:]

    /// The terminal the user is currently looking at (set by ContentView). Used
    /// to suppress the sound/notification while the user is already watching the
    /// session that just started waiting.
    var focusedTaskId: String?

    private var stateWatcher: DispatchSourceFileSystemObject?
    private var statePollTimer: Timer?

    /// Terminal ids backed by tmux (Claude sessions). These persist across Heart
    /// quit, so they're excluded from the aggressive kill in terminateAllSync.
    private var tmuxBackedIds: Set<String> = []
    /// Stable "Terminal N" numbering + closed-terminal memory (for resume).
    private let terminalStore = ClaudeTerminalStore()

    override init() {
        super.init()
        installKeyMonitor()
        installScrollMonitor()
        startStateWatching()
        // tmux-backed persistence: write our isolated config, then adopt any
        // Claude sessions still alive from a previous Heart run.
        TmuxService.writeConfig()
        TmuxService.reloadConfig()
        reattachTmuxSessions()
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
        stateWatcher?.cancel()
    }

    /// Redirect the scroll wheel into tmux copy-mode when the pane under the
    /// cursor is a tmux-backed Claude session (its scrollback lives in tmux, not
    /// SwiftTerm). Returning nil swallows the event so SwiftTerm doesn't also
    /// react; any other pane passes through untouched.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  event.scrollingDeltaY != 0,
                  let hit = event.window?.contentView?.hitTest(event.locationInWindow),
                  let term = Self.enclosingHeartTerminal(hit),
                  let session = term.tmuxSessionName else {
                return event
            }
            let now = Date()
            if now.timeIntervalSince(self.lastScrollSend) >= 0.03 {
                self.lastScrollSend = now
                let lines = event.scrollingDeltaY > 0 ? 3 : -3
                DispatchQueue.global(qos: .userInteractive).async {
                    TmuxService.scroll(session: session, lines: lines)
                }
            }
            return nil   // consume — SwiftTerm's own (empty) scroll shouldn't run
        }
    }

    private static func enclosingHeartTerminal(_ view: NSView) -> HeartTerminalView? {
        var v: NSView? = view
        while let cur = v {
            if let term = cur as? HeartTerminalView { return term }
            v = cur.superview
        }
        return nil
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
        let view = HeartTerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
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
        // Claude Code hook bridge: these are inherited by `claude` (if the user
        // runs it in this terminal) and read by ~/.claude/hooks/heart-hook.sh,
        // which writes this terminal's working/waiting state into claude-state/.
        perTaskEnv.append("HEART_TASK_ID=\(task.id)")
        perTaskEnv.append("HEART_TASK_NAME=\(task.name)")
        let project = task.folder?.split(separator: "/").first.map(String.init) ?? ""
        perTaskEnv.append("HEART_PROJECT=\(project)")
        // Drop any stale state file from a previous run of this id so the dot
        // doesn't flash red before the new session's first hook fires.
        removeStateFile(task.id)

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

    /// Force SwiftTerm to throw away whatever it's caching and redraw the
    /// whole buffer. The user's escape hatch for the (still-not-root-caused)
    /// "every character on its own line" rendering glitch in `claude` and
    /// other dynamic-UI CLIs — and what the auto-recovery wired into
    /// detail-bar task switches calls on their behalf.
    ///
    /// Why each step is here:
    ///   - `terminal.resize(cols:rows:)` re-runs SwiftTerm's layout pass and
    ///     calls TIOCSWINSZ on the child PTY, in case the child cached a
    ///     wrong size (a long-standing suspect for the glitch).
    ///   - `softReset()` clears pending escape state, cursor save/restore,
    ///     scroll regions, charset mode — *without* touching the scrollback
    ///     buffer the user is reading. Critical: this is NOT `reset()`,
    ///     which would wipe the buffer.
    ///   - `refresh(startRow:endRow:)` + `needsDisplay` mark every cell
    ///     dirty so Cocoa repaints the whole canvas, evicting any stale
    ///     glyphs left by escape sequences SwiftTerm parsed badly.
    func repaint(_ taskId: String) {
        guard let view = terminalViews[taskId] else { return }
        let terminal = view.getTerminal()
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        view.resize(cols: cols, rows: rows)
        terminal.softReset()
        terminal.refresh(startRow: 0, endRow: rows)
        view.needsDisplay = true
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
        removeStateFile(taskId)
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
        let number = terminalStore.nextNumber(for: task.id)
        let sid = "claude-session-\(task.id)-\(UUID().uuidString.prefix(8))"
        let session = ClaudeSession(id: sid, name: nil, number: number)
        debugLog("addSession task=\(task.id) → new Terminal \(number) (\(sid))")
        insert(session, for: task.id)
        activeClaudeSession[task.id] = sid
        launchClaudeSession(session, task: task, command: task.command)
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

    /// Open a new Claude session that resumes an existing conversation by UUID
    /// (from the resume picker). Command is built via
    /// `ClaudeSessionService.buildResumeCommand` so flags are escaped safely.
    @discardableResult
    func resumeSession(for task: DevTask, options: ResumeOptions) -> String {
        let number = terminalStore.nextNumber(for: task.id)
        let shortId = String(options.sessionId.uuidString.prefix(8))
        var sid = "claude-resume-\(task.id)-\(shortId)"
        var bump = 2
        while sessions(for: task.id).contains(where: { $0.id == sid }) {
            sid = "claude-resume-\(task.id)-\(shortId)-\(bump)"
            bump += 1
        }
        let trimmedDisplay = options.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionLabel = trimmedDisplay.isEmpty ? nil : trimmedDisplay
        let session = ClaudeSession(id: sid, name: sessionLabel, number: number,
                                    claudeSid: options.sessionId.uuidString)
        insert(session, for: task.id)
        activeClaudeSession[task.id] = sid

        let command = ClaudeSessionService.buildResumeCommand(
            sessionId: options.sessionId,
            forkSession: options.forkSession,
            displayName: sessionLabel,
            initialPrompt: options.initialPrompt
        )
        launchClaudeSession(session, task: task, command: command)
        return sid
    }

    /// Reopen a previously-closed terminal (from the "+" dropdown), reconnecting
    /// to the same Claude conversation and keeping its "Terminal N" identity.
    @discardableResult
    func resumeClosedTerminal(_ closed: ClaudeTerminalStore.Closed, task: DevTask) -> String {
        let sid = "claude-session-\(task.id)-\(UUID().uuidString.prefix(8))"
        let session = ClaudeSession(id: sid, name: closed.name, number: closed.number,
                                    claudeSid: closed.claudeSid)
        insert(session, for: task.id)
        activeClaudeSession[task.id] = sid

        let command: String
        if let csid = closed.claudeSid, !csid.isEmpty {
            command = "claude --resume \(Self.singleQuote(csid))"
        } else {
            command = "claude --continue"
        }
        launchClaudeSession(session, task: task, command: command)
        terminalStore.removeClosed(number: closed.number, for: task.id)
        return sid
    }

    /// Closed terminals for this task that aren't currently open — the resume
    /// list shown under the "+" button.
    func closedTerminals(for taskId: String) -> [ClaudeTerminalStore.Closed] {
        let openNumbers = Set(sessions(for: taskId).map { $0.number })
        return terminalStore.closed(for: taskId).filter { !openNumbers.contains($0.number) }
    }

    /// Forget a closed terminal so it no longer appears in the "+" dropdown.
    /// (The Claude conversation on disk is untouched — this only drops Heart's
    /// resume shortcut for it.)
    func forgetClosedTerminal(_ closed: ClaudeTerminalStore.Closed, task: DevTask) {
        terminalStore.removeClosed(number: closed.number, for: task.id)
        objectWillChange.send()
    }

    func removeSession(taskId: String, sessionId: String) {
        var list = claudeSessions[taskId] ?? []
        // Remember it so it can be resumed from the "+" dropdown.
        if let s = list.first(where: { $0.id == sessionId }) {
            terminalStore.addClosed(
                .init(number: s.number, name: s.name, claudeSid: s.claudeSid, title: s.autoTitle),
                for: taskId)
        }
        if TmuxService.isAvailable { TmuxService.killSession(sessionId) }
        tmuxBackedIds.remove(sessionId)
        list.removeAll { $0.id == sessionId }
        claudeSessions[taskId] = list
        if activeClaudeSession[taskId] == sessionId {
            activeClaudeSession[taskId] = list.last?.id
        }
        removeTerminal(taskId: sessionId)
    }

    func setActiveSession(taskId: String, sessionId: String) {
        activeClaudeSession[taskId] = sessionId
        ensureAttached(sessionId)
    }

    func renameSession(taskId: String, sessionId: String, name: String?) {
        var list = claudeSessions[taskId] ?? []
        guard let idx = list.firstIndex(where: { $0.id == sessionId }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = (trimmed?.isEmpty == false) ? trimmed : nil
        list[idx].name = final
        claudeSessions[taskId] = list
        if TmuxService.isAvailable {
            TmuxService.setOption(sessionId, "@heart_name", final ?? "")
        }
        // Keep the resumable record's name in sync so the "+" dropdown shows the
        // renamed label after a close/reboot.
        let s = list[idx]
        if let sid = s.claudeSid, !sid.isEmpty {
            terminalStore.addClosed(.init(number: s.number, name: final, claudeSid: sid), for: taskId)
        }
    }

    // MARK: - Claude session launch / attach (tmux-backed)

    /// Keep the per-task session list ordered by stable terminal number.
    private func insert(_ session: ClaudeSession, for taskId: String) {
        var list = claudeSessions[taskId] ?? []
        list.append(session)
        list.sort { $0.number < $1.number }
        claudeSessions[taskId] = list
    }

    /// Create-or-attach the tmux session that hosts this Claude terminal. When
    /// tmux isn't installed, falls back to a plain (non-persistent) spawn so the
    /// app still works.
    private func launchClaudeSession(_ session: ClaudeSession, task: DevTask, command: String) {
        let view = terminalView(for: session.id)
        if view.process.running { return }
        statuses[session.id] = .starting
        removeStateFile(session.id)

        let expandedCwd = (task.cwd as NSString).expandingTildeInPath
        let escCwd = expandedCwd.replacingOccurrences(of: "'", with: "'\\''")
        let cols = max(80, view.getTerminal().cols)
        let rows = max(24, view.getTerminal().rows)
        let inner = "cd '\(escCwd)' && exec \(command)"
        let project = task.folder?.split(separator: "/").first.map(String.init) ?? ""
        let hookEnv = ["HEART_TASK_ID": session.id,
                       "HEART_TASK_NAME": task.name,
                       "HEART_PROJECT": project]

        var perTaskEnv = spawnEnvironment
        perTaskEnv.append("COLUMNS=\(cols)")
        perTaskEnv.append("LINES=\(rows)")
        for (k, v) in hookEnv { perTaskEnv.append("\(k)=\(v)") }

        let wrapped: String
        if TmuxService.isAvailable {
            tmuxBackedIds.insert(session.id)
            (view as? HeartTerminalView)?.tmuxSessionName = session.id
            wrapped = TmuxService.launchWrapper(sessionName: session.id, inner: inner,
                                                cols: cols, rows: rows, env: hookEnv)
        } else {
            wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; \(inner)"
        }
        view.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-i", "-c", wrapped],
                          environment: perTaskEnv,
                          execName: nil)
        scheduleReadinessCheck(for: DevTask(id: session.id, name: task.name,
                                            command: command, cwd: task.cwd))
        stampTmuxOptions(session: session, task: task)
    }

    /// Reconnect an inactive/reattached session's terminal view to its live
    /// tmux session. No-op if already running, tmux is absent, or the session
    /// is gone (then it's marked stopped so the user can close/resume it).
    func ensureAttached(_ sessionId: String) {
        guard TmuxService.isAvailable, tmuxBackedIds.contains(sessionId) else { return }
        let view = terminalView(for: sessionId)
        (view as? HeartTerminalView)?.tmuxSessionName = sessionId
        if view.process.running { return }
        guard TmuxService.hasSession(sessionId) else {
            statuses[sessionId] = .stopped
            return
        }
        statuses[sessionId] = .starting
        let cols = max(80, view.getTerminal().cols)
        let rows = max(24, view.getTerminal().rows)
        // inner is ignored on attach (the session already exists).
        let wrapped = TmuxService.launchWrapper(sessionName: sessionId, inner: "true",
                                                cols: cols, rows: rows, env: [:])
        var perTaskEnv = spawnEnvironment
        perTaskEnv.append("COLUMNS=\(cols)")
        perTaskEnv.append("LINES=\(rows)")
        view.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-i", "-c", wrapped],
                          environment: perTaskEnv,
                          execName: nil)
        scheduleReadinessCheck(for: DevTask(id: sessionId, name: "", command: "", cwd: ""))
        debugLog("ensureAttached started \(sessionId)")
        // tmux paints the live pane on attach, but SwiftTerm can miss it and show
        // blank. A real winsize change (not softReset — that corrupts the
        // alt-screen) makes the tmux client SIGWINCH and redraw the whole screen.
        for delay in [0.7, 1.6, 2.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.nudgeRedraw(sessionId)
            }
        }
    }

    /// Force a tmux full redraw by briefly changing the PTY winsize (±1 row),
    /// which the attached tmux client reacts to with a complete repaint. Fixes
    /// the "blank after attach" symptom without softReset's alt-screen damage.
    private func nudgeRedraw(_ sessionId: String) {
        guard let view = terminalViews[sessionId], view.process.running else { return }
        let t = view.getTerminal()
        let c = max(4, t.cols)
        let r = max(4, t.rows)
        view.resize(cols: c, rows: r - 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let v = self?.terminalViews[sessionId], v.process.running else { return }
            v.resize(cols: c, rows: r)
        }
    }

    /// Append a line to `~/Library/Application Support/Heart/heart-debug.log` —
    /// the app's NSLog goes to the unified log where it's hard to filter, so this
    /// gives a reliable, greppable trace of the tmux/reattach flow.
    func debugLog(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let url = HeartPaths.appSupport.appendingPathComponent("heart-debug.log")
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(data)
        } else {
            try? FileManager.default.createDirectory(at: HeartPaths.appSupport,
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    // MARK: - Claude-set titles (tmux pane_title)

    /// Poll tmux for each session's pane title (the topic Claude sets on the
    /// terminal) and adopt it as the tab's auto-title. Runs off the main thread.
    private func refreshPaneTitles() {
        guard TmuxService.isAvailable, !claudeSessions.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let titles = TmuxService.paneTitles()
            guard !titles.isEmpty else { return }
            DispatchQueue.main.async { self?.applyPaneTitles(titles) }
        }
    }

    private func applyPaneTitles(_ titles: [String: String]) {
        for (taskId, list) in claudeSessions {
            var newList = list
            var changed = false
            for i in newList.indices {
                guard let raw = titles[newList[i].id] else { continue }
                let clean = Self.cleanPaneTitle(raw)
                if !clean.isEmpty, newList[i].autoTitle != clean {
                    newList[i].autoTitle = clean
                    changed = true
                }
            }
            if changed { claudeSessions[taskId] = newList }
        }
    }

    /// Strip Claude's leading status glyph (spinner ⠂/⠄…, ✳, ✻ …) and ignore
    /// generic shell/command titles so we only surface a real conversation topic.
    private static func cleanPaneTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, !f.isLetter, !f.isNumber { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["claude", "claude.exe", "zsh", "-zsh", "bash", "sh", "node", "tmux"]
        return generic.contains(s.lowercased()) ? "" : s
    }

    /// Stamp Heart metadata onto the tmux session so it survives Heart restarts.
    /// Retries because `new-session` runs asynchronously inside the PTY.
    private func stampTmuxOptions(session: ClaudeSession, task: DevTask, attempt: Int = 0) {
        guard TmuxService.isAvailable else { return }
        if TmuxService.hasSession(session.id) {
            TmuxService.setOption(session.id, "@heart_task", task.id)
            TmuxService.setOption(session.id, "@heart_num", "\(session.number)")
            TmuxService.setOption(session.id, "@heart_name", session.name ?? "")
            if let sid = session.claudeSid, !sid.isEmpty {
                TmuxService.setOption(session.id, "@claude_sid", sid)
            }
            return
        }
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.stampTmuxOptions(session: session, task: task, attempt: attempt + 1)
        }
    }

    /// Adopt Claude sessions still alive in tmux from a previous Heart run.
    /// Rebuilds the tab list (with numbers/names/ids) but doesn't attach the
    /// terminal views — that happens lazily when the session becomes visible.
    private func reattachTmuxSessions() {
        debugLog("reattach: tmuxPath=\(TmuxService.tmuxPath ?? "nil") available=\(TmuxService.isAvailable)")
        guard TmuxService.isAvailable else { return }
        let live = TmuxService.listSessions()
        debugLog("reattach: found \(live.count) live session(s): " +
                 live.map { "\($0.name)[task=\($0.task) num=\($0.number)]" }.joined(separator: ", "))
        for s in live {
            tmuxBackedIds.insert(s.name)
            terminalStore.bumpCounter(for: s.task, atLeast: s.number)
            if sessions(for: s.task).contains(where: { $0.id == s.name }) { continue }
            insert(ClaudeSession(id: s.name,
                                 name: s.displayName.isEmpty ? nil : s.displayName,
                                 number: s.number,
                                 claudeSid: s.claudeSid.isEmpty ? nil : s.claudeSid),
                   for: s.task)
            if activeClaudeSession[s.task] == nil { activeClaudeSession[s.task] = s.name }
        }
        debugLog("reattach: rebuilt tabs → " +
                 claudeSessions.map { "\($0.key):[\($0.value.map { String($0.number) }.joined(separator: ","))]" }.joined(separator: " "))
    }

    /// Record the Claude conversation id captured by the hook, so a closed
    /// terminal can be resumed to the exact same conversation.
    private func recordClaudeSid(spawnId: String, sid: String) {
        guard !sid.isEmpty else { return }
        for (taskId, list) in claudeSessions {
            guard let idx = list.firstIndex(where: { $0.id == spawnId }) else { continue }
            if list[idx].claudeSid != sid {
                claudeSessions[taskId]?[idx].claudeSid = sid
                if TmuxService.isAvailable { TmuxService.setOption(spawnId, "@claude_sid", sid) }
                // Also remember it as resumable so it survives a *reboot* (which
                // kills the tmux server): while open it's hidden from the "+"
                // dropdown (closedTerminals filters open numbers), but after a
                // reboot the session is gone and it resurfaces there to resume.
                let s = claudeSessions[taskId]![idx]
                terminalStore.addClosed(
                    .init(number: s.number, name: s.name, claudeSid: sid), for: taskId)
            }
            return
        }
    }

    private static func singleQuote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Claude attention (hook bridge)

    /// Aggregated attention for a sidebar task. For a Claude shortcut the actual
    /// `claude` processes are its shadow sessions, so we fold their states in:
    /// `.waiting` if any session/terminal is waiting, else `.working` if any is
    /// working, else `nil` (no Claude running here → caller falls back to the
    /// normal process-status color).
    func attentionFor(_ taskId: String) -> ClaudeAttention? {
        var ids = [taskId]
        ids.append(contentsOf: sessions(for: taskId).map { $0.id })
        var sawWorking = false
        for id in ids {
            switch attention[id] {
            case .waiting: return .waiting
            case .working: sawWorking = true
            case .none: break
            }
        }
        return sawWorking ? .working : nil
    }

    /// Number of `.waiting` Claude sessions among the given tasks (folds shadow
    /// sessions in via `attentionFor`). Drives the red badges in the sidebar
    /// folder headers and the project tab pills.
    func waitingCount(among tasks: [DevTask]) -> Int {
        tasks.reduce(0) { $0 + (attentionFor($1.id) == .waiting ? 1 : 0) }
    }

    /// Watch the claude-state directory for hook-written state files. We rescan
    /// the whole (tiny) directory on every change and reconcile — simple and
    /// resilient to coalesced events.
    private func startStateWatching() {
        let dir = HeartPaths.claudeStateDir
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Wipe stale files whose process is dead — but KEEP files for sessions
        // still alive in tmux (persisted across the last Heart quit), so a
        // waiting Claude shows red immediately on launch instead of only after
        // its next hook fires.
        let liveIds = Set(TmuxService.isAvailable ? TmuxService.listSessions().map { $0.name } : [])
        if let leftovers = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in leftovers where f.pathExtension == "json" {
                let id = f.deletingPathExtension().lastPathComponent
                if !liveIds.contains(id) { try? fm.removeItem(at: f) }
            }
        }

        // Instant reaction via the directory vnode…
        let fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: .main
            )
            src.setEventHandler { [weak self] in self?.rescanState() }
            src.setCancelHandler { close(fd) }
            stateWatcher = src
            src.resume()
        }

        // …plus a 1 s poll as a bulletproof fallback. Atomic `mv` renames and
        // SwiftUI-app runloop quirks can make a lone vnode source miss events;
        // re-scanning a handful of tiny files once a second is free and never
        // misses a transition.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.rescanState()
            self?.refreshPaneTitles()
        }
        RunLoop.main.add(timer, forMode: .common)
        statePollTimer = timer

        rescanState()
    }

    private func rescanState() {
        let dir = HeartPaths.claudeStateDir
        var next: [String: ClaudeAttention] = [:]
        var meta: [String: (name: String, project: String)] = [:]

        if let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                guard let data = try? Data(contentsOf: f),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let state = obj["state"] as? String else { continue }
                let id = f.deletingPathExtension().lastPathComponent
                next[id] = (state == "waiting") ? .waiting : .working
                meta[id] = (obj["name"] as? String ?? "", obj["project"] as? String ?? "")
                // Capture the claude conversation id for resume (independent of
                // the attention-change guard below).
                if let sid = obj["sid"] as? String { recordClaudeSid(spawnId: id, sid: sid) }
            }
        }

        guard next != attention else { return }   // nothing changed → no churn

        // Notify (+ bounce the Dock) on transitions *into* waiting.
        for (id, state) in next where state == .waiting && attention[id] != .waiting {
            maybeNotify(spawnId: id, name: meta[id]?.name ?? "", project: meta[id]?.project ?? "")
        }
        attention = next
        updateDockBadge()
    }

    /// Mirror the total number of waiting Claude sessions onto the Dock icon so
    /// the user is nagged even when Heart is in the background.
    private func updateDockBadge() {
        let waiting = attention.values.filter { $0 == .waiting }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        NSLog("[Heart] attention update: %d waiting, %d tracked", waiting, attention.count)
    }

    /// Total number of Claude sessions currently waiting on the user — drives
    /// the global Dock badge and the clickable top-bar badge.
    var totalWaiting: Int {
        attention.values.filter { $0 == .waiting }.count
    }

    /// Fired on every transition *into* waiting. Always alerts — sound + banner
    /// + Dock bounce — regardless of focus, so a session that needs you never
    /// goes unnoticed.
    private func maybeNotify(spawnId: String, name: String, project: String) {
        // In-process system sound — reliable, no notification permission needed.
        NSSound(named: NSSound.Name("Glass"))?.play()
        NotificationService.notifyWaiting(name: name, project: project)
        // Bounce the Dock icon until the user comes back — keeps nagging.
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func removeStateFile(_ taskId: String) {
        let file = HeartPaths.claudeStateDir.appendingPathComponent("\(taskId).json")
        try? FileManager.default.removeItem(at: file)
        if attention[taskId] != nil { attention[taskId] = nil }
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
        // tmux-backed Claude sessions are intentionally left alive: when the app
        // exits, their PTYs close and the tmux clients detach, so the sessions
        // persist (and reattach next launch). Only kill Heart-owned processes.
        let running = terminalViews
            .filter { $0.value.process.running && !tmuxBackedIds.contains($0.key) }
            .map { $0.value }
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
            self.removeStateFile(taskId)

            if let pending = self.pendingRestart.removeValue(forKey: taskId) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.start(pending)
                }
            }
        }
    }
}
