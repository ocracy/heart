import SwiftUI

/// Sidebar row for browser-kind tasks. No process state, no play/stop — the
/// task is purely a URL bookmark surfaced as its own selectable row. Clicking
/// the row selects it (and the detail pane renders the in-app browser tab).
/// The trailing buttons open the URL in the built-in browser or the system
/// default external browser.
struct BrowserRow: View {
    let task: DevTask
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.blue.opacity(0.16))
                    Image(systemName: task.icon?.isEmpty == false ? task.icon! : "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    if !task.name.isEmpty {
                        Text(task.name)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    if let url = task.url, !url.isEmpty {
                        Text(url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    iconButton(systemName: "globe",
                               tint: .blue,
                               help: "Open in built-in browser",
                               action: onSelect)
                    if let urlString = task.url, !urlString.isEmpty {
                        iconButton(systemName: "arrow.up.right.square",
                                   tint: .purple,
                                   help: "Open URL in default external browser") {
                            TaskRow.openExternal(urlString)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
