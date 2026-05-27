import SwiftUI
import AppKit

/// Sidebar row for github-kind tasks. Mirrors BrowserRow's layout but uses a
/// purple branch icon and surfaces the live git state (branch, ahead/behind,
/// dirty count) underneath the name. No status dot / play / stop — the row is
/// purely a launcher for the GitHub Desktop-style detail pane.
struct GitHubRow: View {
    let task: DevTask
    let isSelected: Bool
    @ObservedObject var gitManager: GitManager
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.purple.opacity(0.16))
                    Image(systemName: task.icon?.isEmpty == false
                          ? task.icon!
                          : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.purple)
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    if !task.name.isEmpty {
                        Text(task.name)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    statusLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    iconButton(systemName: "arrow.clockwise",
                               tint: .purple,
                               help: "Refresh git status") {
                        Task { await gitManager.refresh(taskId: task.id, cwd: task.cwd) }
                    }
                    iconButton(systemName: "folder",
                               tint: .blue,
                               help: "Show repo in Finder") {
                        let expanded = GitManager.expand(task.cwd)
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: expanded)]
                        )
                    }
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { await gitManager.refresh(taskId: task.id, cwd: task.cwd) }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let state = gitManager.states[task.id] {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(state.branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if state.ahead > 0 {
                    Text("↑\(state.ahead)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if state.behind > 0 {
                    Text("↓\(state.behind)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                if state.totalChangedCount > 0 {
                    Text("±\(state.totalChangedCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.purple)
                }
            }
        } else {
            Text(displayPath(task.cwd))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    @ViewBuilder
    private func iconButton(systemName: String,
                            tint: Color,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(tint.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
