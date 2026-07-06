import Foundation

/// Shared on-disk locations Heart and the Claude hook script both rely on.
enum HeartPaths {
    static var appSupport: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heart", isDirectory: true)
    }

    /// One JSON file per running terminal (`<HEART_TASK_ID>.json`) describing
    /// whether the Claude session in that terminal is `working` or `waiting`.
    /// Written by the hook script, watched by `ProcessManager`.
    static var claudeStateDir: URL {
        appSupport.appendingPathComponent("claude-state", isDirectory: true)
    }

    static var claudeHookScript: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/hooks/heart-hook.sh")
    }

    static var claudeSettings: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }
}

/// Installs (idempotently) the Claude Code hooks that bridge a Claude session's
/// working/waiting state back to Heart's UI.
///
/// How it works: Claude Code hooks inherit the environment of the `claude`
/// process, which inherits the env Heart injects when it spawns the terminal
/// (`HEART_TASK_ID` / `HEART_TASK_NAME` / `HEART_PROJECT`, see
/// `ProcessManager.start`). The hook script reads those, and writes a tiny
/// state file Heart watches. Outside Heart `HEART_TASK_ID` is unset, so the
/// script is a no-op — zero side effects on the user's other Claude sessions.
enum ClaudeHookInstaller {

    /// Event → state-argument the hook script is invoked with.
    private static let eventStates: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),   // user sent a prompt → Claude starts working
        ("PreToolUse",       "working"),   // tool loop active (also: after a permission is approved)
        ("PostToolUse",      "working"),
        ("SessionStart",     "working"),
        ("Stop",             "waiting"),    // response finished → awaiting next input
        ("Notification",     "waiting"),    // permission / decision / idle prompt
        ("SessionEnd",       "end"),        // session closed → delete the state file
    ]

    /// Write the hook script and merge our hook entries into the user's global
    /// `~/.claude/settings.json`, preserving everything already there.
    static func installIfNeeded() {
        writeScript()
        mergeSettings()
    }

    // MARK: - script

    private static func writeScript() {
        let url = HeartPaths.claudeHookScript
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try scriptBody.write(to: url, atomically: true, encoding: .utf8)
            // chmod 0755 so Claude Code can exec it.
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        } catch {
            NSLog("[ClaudeHookInstaller] writeScript failed: %@", "\(error)")
        }
    }

    private static let scriptBody = """
    #!/bin/sh
    # Heart <-> Claude Code bridge hook. Managed by Heart.app — do not edit.
    # Reports the Claude session's working/waiting state (and its claude
    # session_id, for resume) to a per-terminal file Heart watches. No-op
    # outside Heart (HEART_TASK_ID unset), so it never affects other sessions.
    state="$1"

    # Read stdin (Claude pipes the event JSON) so its write never blocks; we
    # pull session_id out of it below.
    input=$(cat 2>/dev/null)

    [ -z "$HEART_TASK_ID" ] && exit 0

    dir="$HOME/Library/Application Support/Heart/claude-state"
    file="$dir/$HEART_TASK_ID.json"

    if [ "$state" = "end" ]; then
      rm -f "$file" 2>/dev/null
      exit 0
    fi

    mkdir -p "$dir" 2>/dev/null
    esc() { printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([0-9a-fA-F-]*\\)".*/\\1/p' | head -1)
    name=$(esc "$HEART_TASK_NAME")
    project=$(esc "$HEART_PROJECT")
    ts=$(date +%s)
    tmp="$file.$$.tmp"
    printf '{"state":"%s","name":"%s","project":"%s","sid":"%s","ts":%s}' \\
      "$state" "$name" "$project" "$sid" "$ts" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null
    exit 0
    """

    // MARK: - settings.json merge

    private static func mergeSettings() {
        let url = HeartPaths.claudeSettings
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Don't clobber a settings file we can't parse (comments / corruption).
                NSLog("[ClaudeHookInstaller] could not parse settings.json — skipping merge")
                return
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let scriptPath = HeartPaths.claudeHookScript.path
        var changed = false

        for (event, state) in eventStates {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Idempotent: skip if any entry already points at our script.
            let alreadyInstalled = entries.contains { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { ($0["command"] as? String)?.contains("heart-hook.sh") == true }
            }
            if alreadyInstalled { continue }

            entries.append([
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": "\(scriptPath) \(state)",
                    "timeout": 5,
                    "async": true,
                ]],
            ])
            hooks[event] = entries
            changed = true
        }

        guard changed else { return }
        root["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            NSLog("[ClaudeHookInstaller] merged Heart hooks into %@", url.path)
        } catch {
            NSLog("[ClaudeHookInstaller] write settings.json failed: %@", "\(error)")
        }
    }
}
