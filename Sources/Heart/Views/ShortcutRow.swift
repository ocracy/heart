import SwiftUI

/// Sidebar row for a `kind: "shortcut"` task — a generic command launcher
/// (think ssh, kubectl, scp, custom REPLs). No play/stop buttons, no port
/// chips: the row is a button. Tapping it starts the command if it isn't
/// already running and selects the row so the terminal fills the detail
/// pane. Restarting / stopping is one right-click away.
///
/// Looks similar to ClaudeShortcutRow but uses a neutral icon + the task's
/// command as the subtitle (vs. cwd) since the command is the whole point
/// of these tasks.
struct ShortcutRow: View {
    let task: DevTask
    let isSelected: Bool
    @ObservedObject var processManager: ProcessManager
    let onTap: () -> Void

    private var status: TaskStatus { processManager.status(task.id) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.icon ?? "arrow.right.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if !task.name.isEmpty {
                        Text(task.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    // Subtle status dot — only visible while a session is alive.
                    // No button: stopping is a right-click action, not a primary one.
                    if status.isRunning {
                        Circle()
                            .fill(status.color)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(task.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
