import SwiftUI

struct TaskRow: View {
    let task: DevTask
    @ObservedObject var processManager: ProcessManager
    var onShowBrowser: (() -> Void)? = nil

    private var status: TaskStatus { processManager.status(task.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(status.color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let icon = task.icon, !icon.isEmpty {
                        Image(systemName: icon)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    if !task.name.isEmpty {
                        Text(task.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    if let port = task.port {
                        // verbatim: avoid Turkish-locale grouping like "8 000" / "8.000"
                        Text(verbatim: ":\(port)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(task.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if task.url != nil, let onShowBrowser {
                    iconButton(systemName: "globe",
                               tint: .blue,
                               help: "Open URL in built-in browser") {
                        onShowBrowser()
                    }
                }

                toggleButton

                iconButton(systemName: "arrow.clockwise",
                           tint: .secondary,
                           help: "Restart") {
                    processManager.restart(task)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var toggleButton: some View {
        let tint: Color = {
            switch status {
            case .running: return .red
            case .starting, .stopping: return .yellow
            default: return .green
            }
        }()

        let helpText: String = {
            switch status {
            case .running: return "Stop (Ctrl+C → SIGTERM → SIGKILL)"
            case .starting: return "Starting… (click to cancel)"
            case .stopping: return "Stopping…"
            default: return "Start"
            }
        }()

        Button {
            processManager.toggle(task)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(tint.opacity(0.25), lineWidth: 0.5)
                    )

                switch status {
                case .starting, .stopping:
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                        .tint(tint)
                case .running:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                default:
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .disabled(status == .stopping)
    }

    @ViewBuilder
    private func iconButton(systemName: String,
                            tint: Color,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
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
