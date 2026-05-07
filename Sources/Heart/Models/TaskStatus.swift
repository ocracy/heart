import SwiftUI

enum TaskStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case crashed(exitCode: Int32)

    var isRunning: Bool {
        if case .running = self { return true }
        if case .starting = self { return true }
        if case .stopping = self { return true }
        return false
    }

    var color: Color {
        switch self {
        case .running: return .green
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
        case .stopping: return "Stopping…"
        case .crashed(let code): return "Crashed (exit \(code))"
        }
    }
}
