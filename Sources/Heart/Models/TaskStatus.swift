import SwiftUI

enum TaskStatus: Equatable {
    case stopped
    case starting
    case running
    /// Port is bound by a process Heart did NOT spawn (detected via TCP probe).
    /// We surface the row as alive — green sidebar dot, stop button works (via
    /// killPort) — but the detail pane shows an explanatory overlay because we
    /// can't pipe the foreign process's stdout into our terminal view.
    case externalRunning
    case stopping
    case crashed(exitCode: Int32)

    var isRunning: Bool {
        switch self {
        case .running, .starting, .stopping, .externalRunning: return true
        default: return false
        }
    }

    /// True only when Heart spawned this process itself and it's currently alive
    /// — distinguishes "we own the PTY, output flows into our terminal" from a
    /// foreign service that happens to be bound to the same port.
    var isOwnedByHeart: Bool {
        switch self {
        case .running, .starting, .stopping: return true
        default: return false
        }
    }

    var color: Color {
        switch self {
        case .running: return .green
        case .externalRunning: return Color(red: 0.4, green: 0.8, blue: 0.4)
        case .starting, .stopping: return .yellow
        case .stopped: return .gray
        case .crashed: return .red
        }
    }

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .externalRunning: return "External"
        case .stopping: return "Stopping…"
        case .crashed(let code): return "Crashed (exit \(code))"
        }
    }
}
