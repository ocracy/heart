import Foundation

/// Runs Heart's Claude terminals inside a **dedicated, isolated tmux server**
/// (`-L heart`, own socket + minimal config) so they survive Heart quitting and
/// can be resumed after a reboot. Isolation means Heart never touches the user's
/// own tmux sessions or `~/.tmux.conf`.
///
/// Each Heart session becomes one tmux session whose name IS the Heart session
/// id (alphanumeric + hyphen, tmux-safe). Metadata is stored as tmux *user
/// options* on the session so it also survives Heart restarts:
///   - `@heart_task`   : the parent Claude-shortcut task id
///   - `@heart_num`    : the stable terminal number ("Terminal N")
///   - `@heart_name`   : the user's custom display name (may be empty)
///   - `@claude_sid`   : the claude conversation id, captured for resume
enum TmuxService {
    /// **Explicit** socket path (not `-L name`). Critical: with `-L heart` tmux
    /// derives the socket dir from `$TMUX_TMPDIR` (or a macOS per-launch Darwin
    /// temp dir), which DIFFERS between the app's launchd environment and the
    /// login shell that spawns the panes — so `list-sessions` would sometimes
    /// look at an empty socket and miss still-alive sessions, spawning
    /// duplicates. A fixed `-S` path under /tmp is identical for every caller.
    static let socketPath = "/tmp/heart-tmux-\(getuid()).sock"

    /// Absolute tmux path (Homebrew/MacPorts/system). GUI apps get a minimal
    /// PATH, so we can't rely on a bare `tmux` from Process.
    static let tmuxPath: String? = {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                          "/opt/local/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { tmuxPath != nil }

    static var configPath: String {
        HeartPaths.appSupport.appendingPathComponent("heart-tmux.conf").path
    }

    // MARK: - Config

    /// Minimal, conservative config chosen to keep Claude's TUI rendering clean
    /// inside SwiftTerm (the historical "every character on its own line" bug):
    /// no status bar, standard `screen-256color` (universally present terminfo)
    /// with truecolor passthrough, instant escape handling, and no clipboard /
    /// mouse / focus escapes that SwiftTerm would have to round-trip.
    static func writeConfig() {
        let body = """
        set -g status off
        set -sg escape-time 0
        set -g default-terminal "screen-256color"
        set -as terminal-features ",*:RGB"
        set -g history-limit 50000
        set -g destroy-unattached off
        # Mouse OFF: Heart drives scroll itself (via a scroll-wheel monitor →
        # tmux copy-mode), so tmux must NOT grab the mouse — otherwise it steals
        # drag-to-select and the user can't select/copy text natively in SwiftTerm.
        set -g mouse off
        set -g focus-events off
        set -g set-clipboard off
        set -g aggressive-resize off
        """
        try? FileManager.default.createDirectory(at: HeartPaths.appSupport,
                                                 withIntermediateDirectories: true)
        try? body.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Apply the config to an already-running server (persisted from a previous
    /// Heart run) so option changes like `mouse on` take effect on existing
    /// sessions without recreating them. New servers pick it up via `-f`.
    static func reloadConfig() {
        guard run(["list-sessions"]).status == 0 else { return }   // server alive?
        _ = run(["source-file", configPath])
    }

    // MARK: - Launch command

    /// The string handed to `zsh -l -i -c` that creates-or-attaches the tmux
    /// session. `-A -D`: attach if it already exists (detaching any stale
    /// client), otherwise create and run `inner`. On attach, `inner` is ignored
    /// so a still-running Claude is reconnected rather than restarted.
    static func launchWrapper(sessionName: String,
                              inner: String,
                              cols: Int,
                              rows: Int,
                              env: [String: String]) -> String {
        let tmux = tmuxPath ?? "tmux"
        var parts = [
            "exec", esc(tmux),
            "-S", esc(socketPath),
            "-f", esc(configPath),
            "new-session", "-A", "-D",
            "-s", esc(sessionName),
            "-x", "\(cols)", "-y", "\(rows)",
        ]
        for (k, v) in env {
            parts.append("-e")
            parts.append("\(k)=\(esc(v))")
        }
        parts.append(esc(inner))
        return parts.joined(separator: " ")
    }

    // MARK: - Session queries / mutations

    struct Session {
        let name: String        // == Heart session id
        let task: String        // parent task id (@heart_task)
        let number: Int         // @heart_num
        let displayName: String // @heart_name (may be "")
        let claudeSid: String   // @claude_sid (may be "")
        let attached: Bool
    }

    /// All Heart-owned tmux sessions (those carrying `@heart_task`).
    static func listSessions() -> [Session] {
        let fmt = "#{session_name}\t#{@heart_task}\t#{@heart_num}\t#{@heart_name}\t#{@claude_sid}\t#{session_attached}"
        guard let out = run(["list-sessions", "-F", fmt]).out else { return [] }
        var result: [Session] = []
        for line in out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 6, !f[1].isEmpty else { continue }   // must have @heart_task
            result.append(Session(
                name: f[0],
                task: f[1],
                number: Int(f[2]) ?? 0,
                displayName: f[3],
                claudeSid: f[4],
                attached: f[5] != "0"
            ))
        }
        return result
    }

    static func hasSession(_ name: String) -> Bool {
        run(["has-session", "-t", name]).status == 0
    }

    /// `[sessionName: paneTitle]` for every pane — the title is what the running
    /// app (Claude) set via an OSC title escape, i.e. its conversation topic.
    static func paneTitles() -> [String: String] {
        guard let out = run(["list-panes", "-a", "-F", "#{session_name}\t#{pane_title}"]).out
        else { return [:] }
        var result: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2 else { continue }
            result[f[0]] = f[1]
        }
        return result
    }

    static func killSession(_ name: String) {
        _ = run(["kill-session", "-t", name])
    }

    /// Scroll a session's history via copy-mode. `lines > 0` scrolls up (into
    /// history); `< 0` scrolls back down. Entering copy-mode with `-e` auto-exits
    /// once scrolled to the bottom so typing resumes without a manual `q`.
    static func scroll(session: String, lines: Int) {
        guard lines != 0 else { return }
        if lines > 0 {
            _ = run(["copy-mode", "-e", "-t", session, ";",
                     "send-keys", "-t", session, "-X", "-N", "\(lines)", "scroll-up"])
        } else {
            _ = run(["send-keys", "-t", session, "-X", "-N", "\(-lines)", "scroll-down"])
        }
    }

    static func setOption(_ name: String, _ key: String, _ value: String) {
        _ = run(["set-option", "-t", name, key, value])
    }

    // MARK: - Private

    /// Wrap a value in single quotes for safe embedding in the `zsh -c` string
    /// (`'` → `'\''`). Same trick as ProcessManager/ClaudeSessionService.
    private static func esc(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ args: [String]) -> (out: String?, status: Int32) {
        guard let tmux = tmuxPath else { return (nil, -1) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-S", socketPath] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (nil, -1)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8), p.terminationStatus)
    }
}
