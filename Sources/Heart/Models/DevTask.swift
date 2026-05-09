import Foundation

struct DevTask: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var command: String
    var cwd: String
    var port: Int?
    var url: String?
    var autoStart: Bool
    var folder: String?
    /// Behavior tag. `"claude"` makes the task a multi-session shortcut pinned at the top
    /// of the sidebar; clicking it opens a fresh terminal session each time. `nil` = regular service.
    var kind: String?

    init(id: String = UUID().uuidString,
         name: String,
         command: String,
         cwd: String,
         port: Int? = nil,
         url: String? = nil,
         autoStart: Bool = false,
         folder: String? = nil,
         kind: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.port = port
        self.url = url
        self.autoStart = autoStart
        self.folder = folder
        self.kind = kind
    }

    var isClaudeShortcut: Bool { kind == "claude" }
}

/// Importable JSON shape: `{ "name": "Maatrics", "tasks": [...] }`. The legacy bare-array
/// format `[...]` is also accepted at decode time (see ContentView.presentImport).
struct TaskBundle: Codable {
    var name: String?
    var tasks: [DevTask]
}

/// One terminal session for a Claude-shortcut task. Lives in ProcessManager (per-task list)
/// so it persists across selection changes — switching to another task and back keeps the
/// open sessions intact.
struct ClaudeSession: Identifiable, Equatable, Hashable {
    let id: String
    /// User-supplied display name. `nil` falls back to "Terminal {index+1}".
    var name: String?
}
