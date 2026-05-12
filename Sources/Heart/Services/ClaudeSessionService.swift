import Foundation

/// Heart talks to Claude Code's on-disk session store at
/// `~/.claude/projects/{encoded-cwd}/{session-uuid}.jsonl`. Anthropic's CLI
/// reference (https://code.claude.com/docs/en/cli-reference) documents
/// `claude --resume <id>` as the canonical re-entry point but ships no
/// machine-readable list-sessions command — the picker is interactive only.
/// So this service is the one place that:
///   1) Enumerates the session files for a given cwd.
///   2) Reads just enough of each JSONL to produce a UI preview.
///   3) Builds a properly-escaped shell command for `claude --resume`.
///
/// Everything is `static` and side-effect-free; the only IO is filesystem
/// reads. Keeping the SwiftUI sheet decoupled from this lets us swap in a
/// different transport later (e.g. an official `claude sessions list --json`
/// command if it ships) without touching the picker UI.
enum ClaudeSessionService {

    // MARK: - Public model

    struct SessionInfo: Identifiable, Hashable {
        let id: UUID
        let fileURL: URL
        let modifiedAt: Date
        /// Total size on disk; cheaper to read than counting JSONL lines and a
        /// good proxy for "how much conversation is in here". Matches the
        /// official `claude --resume` picker's metadata column.
        let fileSizeBytes: Int64
        /// First user message in the conversation, truncated to ~200 chars.
        /// Empty string when no user message could be decoded (rare — sessions
        /// always start with a user turn, but defensive against malformed files).
        let preview: String
    }

    enum ServiceError: LocalizedError {
        case directoryUnreadable(URL, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .directoryUnreadable(let url, let error):
                return "Couldn't read \(url.path): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Path utilities

    /// Convert an absolute cwd into the `~/.claude/projects/...` directory
    /// segment that Claude Code uses. Tilde is expanded; all `/` become `-`.
    static func encodedProjectPath(forCwd cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        return expanded.replacingOccurrences(of: "/", with: "-")
    }

    static func sessionsDirectory(forCwd cwd: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encodedProjectPath(forCwd: cwd), isDirectory: true)
    }

    // MARK: - Scan

    /// Enumerate session files in the cwd, decoded into SessionInfo records.
    /// Files whose names aren't valid UUIDs are skipped silently (defensive
    /// against stray files the CLI may write into the project directory).
    /// Sorted most-recent first by file modification date.
    static func scan(cwd: String) throws -> [SessionInfo] {
        let dir = sessionsDirectory(forCwd: cwd)
        let fm = FileManager.default
        // Missing directory = empty result (not an error). Claude only creates
        // it on first session in that cwd.
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ServiceError.directoryUnreadable(dir, underlying: error)
        }

        let results: [SessionInfo] = urls.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: stem) else { return nil }

            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let preview = firstUserMessage(at: url) ?? ""
            return SessionInfo(
                id: uuid,
                fileURL: url,
                modifiedAt: mtime,
                fileSizeBytes: size,
                preview: preview
            )
        }

        return results.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Resume command builder

    /// Build the shell command Heart will hand to zsh to resume a session.
    /// Caller is responsible for prepending `cd <cwd>` (ProcessManager.start
    /// already does this).
    static func buildResumeCommand(sessionId: UUID,
                                   forkSession: Bool,
                                   displayName: String?,
                                   initialPrompt: String?) -> String {
        var parts: [String] = ["claude", "--resume", shellEscape(sessionId.uuidString)]
        if forkSession {
            parts.append("--fork-session")
        }
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            parts.append(contentsOf: ["-n", shellEscape(name)])
        }
        if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            parts.append(shellEscape(prompt))
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Private helpers

    /// Wrap a string in single quotes for safe interpolation into a zsh -c
    /// argument. Mirrors the escapedCwd trick in ProcessManager.start —
    /// inner `'` becomes `'\''` (close, literal-single-quote, reopen).
    private static func shellEscape(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Walk the JSONL one line at a time, collecting decoded user messages,
    /// and return the first one that looks like a real human prompt — i.e.
    /// not a Claude Code internal envelope (`<command-message>...`,
    /// `<command-name>...`, `<local-command-caveat>...` etc.). If every
    /// candidate is a wrapper, fall back to a tag-stripped version of the
    /// earliest one so the preview at least shows the slash-command name.
    /// Stops once we've inspected ~10 user turns or scanned 4 MB.
    private static func firstUserMessage(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let decoder = JSONDecoder()
        let chunkSize = 64 * 1024
        var leftover = Data()
        var scanned = 0
        let maxScan = 4 * 1024 * 1024
        let maxCandidates = 10
        var candidates: [String] = []

        func process(_ lineData: Data) -> Bool {
            guard let raw = decodeUserMessage(lineData, decoder: decoder) else { return false }
            candidates.append(raw)
            return candidates.count >= maxCandidates
        }

        outer: while scanned < maxScan {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            scanned += chunk.count
            leftover.append(chunk)
            let newline: UInt8 = 0x0A
            while let nlIndex = leftover.firstIndex(of: newline) {
                let lineData = leftover.subdata(in: 0..<nlIndex)
                leftover.removeSubrange(0...nlIndex)
                if process(lineData) { break outer }
            }
        }
        if candidates.count < maxCandidates, !leftover.isEmpty {
            _ = process(leftover)
        }

        // Prefer a candidate that isn't a Claude Code system envelope.
        if let plain = candidates.first(where: { !looksLikeSystemEnvelope($0) }) {
            return truncatePreview(plain)
        }
        // All candidates are wrappers — surface the first one with its tags
        // stripped so the user at least sees the slash-command name.
        if let first = candidates.first {
            let cleaned = stripSystemEnvelopeTags(first)
            return cleaned.isEmpty ? nil : truncatePreview(cleaned)
        }
        return nil
    }

    private static func decodeUserMessage(_ data: Data, decoder: JSONDecoder) -> String? {
        guard !data.isEmpty,
              let env = try? decoder.decode(UserEnvelope.self, from: data),
              env.type == "user" else {
            return nil
        }
        let raw = env.message.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// Heuristic: Claude Code wraps slash-command invocations and other
    /// non-human turns in `<command-message>`, `<command-name>`,
    /// `<local-command-caveat>`, `<command-stdout>`, etc. Anything starting
    /// with `<` that looks like such a tag is treated as system noise.
    private static func looksLikeSystemEnvelope(_ s: String) -> Bool {
        let lower = s.lowercased()
        let markers = [
            "<command-message",
            "<command-name",
            "<command-args",
            "<command-stdout",
            "<command-stderr",
            "<local-command",
            "<system-reminder",
            "<bash-input"
        ]
        return markers.contains(where: lower.hasPrefix)
    }

    /// Strip the matching open/close tags so a wrapped slash-command preview
    /// reduces to its argument text (`<command-name>/foo</command-name>` →
    /// `/foo`). Regex is intentionally non-greedy.
    private static func stripSystemEnvelopeTags(_ s: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        let stripped = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        return stripped
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncatePreview(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if collapsed.count <= 200 { return collapsed }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: 200)
        return String(collapsed[..<cutoff]) + "…"
    }

    // MARK: - Codable helpers

    /// Minimal envelope for the lines we care about. Other fields in the JSONL
    /// (parentUuid, promptId, etc.) are ignored.
    private struct UserEnvelope: Decodable {
        let type: String
        let message: MessageBody
    }

    private struct MessageBody: Decodable {
        let content: FlexibleContent
    }

    /// Claude's `content` is either a plain string (older / simple turns) or
    /// an array of content blocks (`{type: "text", text: "..."}` plus images,
    /// tool calls, etc.). For the preview we only need text — everything else
    /// is dropped silently.
    private struct FlexibleContent: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self.text = single
                return
            }
            let blocks = (try? container.decode([Block].self)) ?? []
            self.text = blocks.compactMap(\.text).joined(separator: " ")
        }

        private struct Block: Decodable {
            let type: String
            let text: String?
        }
    }
}
