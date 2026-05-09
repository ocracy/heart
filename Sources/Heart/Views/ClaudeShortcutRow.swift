import SwiftUI

/// Sidebar row for a Claude-shortcut task. Looks similar to `TaskRow` but drops the
/// status indicator, port chip and play/stop/restart buttons — clicking the row just
/// selects it and the detail pane shows the multi-session UI.
struct ClaudeShortcutRow: View {
    let task: DevTask
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.purple)
                .frame(width: 10, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("CLAUDE")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(displayPath(task.cwd))
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

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
