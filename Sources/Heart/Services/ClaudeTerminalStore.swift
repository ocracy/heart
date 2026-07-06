import Foundation

/// Disk persistence for Claude terminals: the stable per-task "Terminal N"
/// counter, and the list of *closed-but-resumable* terminals shown in the "+"
/// dropdown. Live terminals' source of truth is tmux (see `TmuxService`); this
/// store only holds what tmux can't after a reboot.
///
/// File: `~/Library/Application Support/Heart/claude-terminals.json`.
final class ClaudeTerminalStore {
    /// A terminal the user closed — remembered so it can be resumed under the
    /// same number/name, reconnecting to the same Claude conversation.
    struct Closed: Codable, Equatable {
        var number: Int
        var name: String? = nil
        var claudeSid: String? = nil
        /// Last-known Claude title, so the "+" dropdown shows the conversation
        /// topic instead of a bare "Terminal N".
        var title: String? = nil
    }

    private struct TaskRecord: Codable {
        var counter: Int = 0
        var closed: [Closed] = []
    }

    private var records: [String: TaskRecord] = [:]
    private let url = HeartPaths.appSupport.appendingPathComponent("claude-terminals.json")

    init() { load() }

    /// Next stable number for a task (monotonic, never reused).
    func nextNumber(for taskId: String) -> Int {
        var r = records[taskId] ?? TaskRecord()
        r.counter += 1
        records[taskId] = r
        save()
        return r.counter
    }

    /// Make sure the counter is at least `n` — called when reattaching tmux
    /// sessions on launch so future numbers don't collide with restored ones.
    func bumpCounter(for taskId: String, atLeast n: Int) {
        var r = records[taskId] ?? TaskRecord()
        if r.counter < n {
            r.counter = n
            records[taskId] = r
            save()
        }
    }

    func closed(for taskId: String) -> [Closed] {
        records[taskId]?.closed ?? []
    }

    func addClosed(_ c: Closed, for taskId: String) {
        var r = records[taskId] ?? TaskRecord()
        r.closed.removeAll { $0.number == c.number }
        r.closed.insert(c, at: 0)
        if r.closed.count > 30 { r.closed = Array(r.closed.prefix(30)) }
        records[taskId] = r
        save()
    }

    func removeClosed(number: Int, for taskId: String) {
        guard var r = records[taskId] else { return }
        r.closed.removeAll { $0.number == number }
        records[taskId] = r
        save()
    }

    // MARK: - IO

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: TaskRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(at: HeartPaths.appSupport,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
