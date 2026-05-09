import SwiftUI

/// Detail view for a Claude-shortcut task. Sessions are stored on `ProcessManager` so they
/// persist across sidebar selection changes (switching tasks and coming back keeps every
/// open Claude terminal alive). Each pill renders a status dot, the session name (with an
/// inline pencil-icon rename), and a close button.
struct ClaudeDetailView: View {
    let task: DevTask
    @ObservedObject var processManager: ProcessManager

    @State private var renamingSessionId: String?
    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        let sessions = processManager.sessions(for: task.id)
        let active = processManager.activeSession(for: task.id)
        VStack(spacing: 0) {
            header(sessionCount: sessions.count)
            Divider()
            tabBar(sessions: sessions, active: active)
            Divider()
            content(sessions: sessions, active: active)
        }
        .onAppear {
            if processManager.sessions(for: task.id).isEmpty {
                processManager.addSession(for: task)
            }
        }
    }

    private func header(sessionCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(Color.purple)
            Text(task.name)
                .font(.headline)
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.secondary)
            Text(verbatim: task.cwd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func tabBar(sessions: [ClaudeSession], active: String?) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, session in
                sessionPill(session: session,
                            fallbackLabel: "Terminal \(idx + 1)",
                            isActive: active == session.id)
            }
            Button {
                processManager.addSession(for: task)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help("Open another Claude session")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func sessionPill(session: ClaudeSession,
                             fallbackLabel: String,
                             isActive: Bool) -> some View {
        let status = processManager.status(session.id)
        let isRenaming = renamingSessionId == session.id
        let displayName = session.name?.isEmpty == false ? session.name! : fallbackLabel

        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)

            if isRenaming {
                TextField(fallbackLabel, text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 80, idealWidth: 120)
                    .fixedSize()
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(for: session) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(displayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
            }

            Button {
                if isRenaming {
                    commitRename(for: session)
                } else {
                    startRename(session: session, fallback: fallbackLabel)
                }
            } label: {
                Image(systemName: isRenaming ? "checkmark" : "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help(isRenaming ? "Save name (Enter)" : "Rename session")

            Button {
                processManager.removeSession(taskId: task.id, sessionId: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("Close this session (kills the process)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                        lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isRenaming {
                processManager.setActiveSession(taskId: task.id, sessionId: session.id)
            }
        }
    }

    @ViewBuilder
    private func content(sessions: [ClaudeSession], active: String?) -> some View {
        if sessions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.purple.opacity(0.6))
                Text("No sessions")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Button {
                    processManager.addSession(for: task)
                } label: {
                    Label("Open Claude session", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                ForEach(sessions, id: \.id) { session in
                    OutputView(terminalView: processManager.terminalView(for: session.id))
                        .opacity(active == session.id ? 1 : 0)
                        .allowsHitTesting(active == session.id)
                }
            }
        }
    }

    private func startRename(session: ClaudeSession, fallback: String) {
        renamingSessionId = session.id
        renameText = session.name ?? ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            renameFieldFocused = true
        }
    }

    private func commitRename(for session: ClaudeSession) {
        processManager.renameSession(taskId: task.id,
                                      sessionId: session.id,
                                      name: renameText)
        renamingSessionId = nil
        renameText = ""
    }

    private func cancelRename() {
        renamingSessionId = nil
        renameText = ""
    }
}
