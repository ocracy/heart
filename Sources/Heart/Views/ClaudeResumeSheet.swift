import SwiftUI
import AppKit

/// Picker dialog for resuming a previous Claude Code conversation that lives
/// in the same `cwd` as a Claude shortcut task. The layout intentionally
/// mirrors the official `claude --resume` interactive picker: a compact,
/// terminal-style list with a search box, a `>` chevron on the active row,
/// and a two-line entry (preview + relative time · file size). No cards or
/// rounded chips — dense and scan-friendly.
struct ClaudeResumeSheet: View {
    let task: DevTask
    let onCancel: () -> Void
    let onResume: (ProcessManager.ResumeOptions) -> Void

    enum LoadPhase {
        case loading
        case loaded([ClaudeSessionService.SessionInfo])
        case empty
        case error(String)
    }

    @State private var phase: LoadPhase = .loading
    @State private var selectedId: UUID?
    @State private var forkSession: Bool = false
    @State private var initialPrompt: String = ""
    @State private var searchQuery: String = ""

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
            Divider()
            optionsAndFooter
        }
        .frame(width: 720, height: 620)
        .background(Color(NSColor.windowBackgroundColor))
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.purple.opacity(0.15))
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.purple)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Resume Session")
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: countLabel)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(displayPath(task.cwd))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(task.cwd)
                    .onTapGesture {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: (task.cwd as NSString).expandingTildeInPath)]
                        )
                    }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var countLabel: String {
        switch phase {
        case .loaded(let sessions):
            let filtered = filteredSessions(in: sessions).count
            return filtered == sessions.count ? "(\(sessions.count))" : "(\(filtered) of \(sessions.count))"
        case .empty:
            return "(0)"
        default:
            return ""
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
    }

    // MARK: - List content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading session history…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            placeholder(icon: "tray",
                        title: "No previous sessions",
                        message: "Claude Code hasn't recorded a session in this directory yet.")
        case .error(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.orange)
                Text("Couldn't read sessions")
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("Retry") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let sessions):
            let filtered = filteredSessions(in: sessions)
            if filtered.isEmpty {
                placeholder(icon: "magnifyingglass",
                            title: "No matches",
                            message: "Nothing in this cwd matches \"\(searchQuery)\".")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { info in
                            sessionRow(info)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func sessionRow(_ info: ClaudeSessionService.SessionInfo) -> some View {
        let isSelected = (selectedId == info.id)
        HStack(alignment: .top, spacing: 8) {
            // Chevron column — only visible on the active row.
            Text(verbatim: isSelected ? ">" : " ")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : .clear)
                .frame(width: 12, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.preview.isEmpty ? "(no message)" : info.preview)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(info.preview.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(relativeDate(info.modifiedAt))
                    Text(verbatim: "·").foregroundStyle(.secondary.opacity(0.5))
                    Text(humanSize(info.fileSizeBytes))
                    Text(verbatim: "·").foregroundStyle(.secondary.opacity(0.5))
                    Text(verbatim: info.id.uuidString.prefix(8).lowercased())
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedId = info.id }
    }

    // MARK: - Options + footer

    @ViewBuilder
    private var optionsAndFooter: some View {
        VStack(spacing: 0) {
            if case .loaded = phase {
                HStack(alignment: .top, spacing: 16) {
                    Toggle(isOn: $forkSession) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Fork as a new session")
                                .font(.system(size: 12, weight: .medium))
                            Text("Original conversation stays untouched.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Optional starting message")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.4)
                        TextField("(empty = just continue)", text: $initialPrompt)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(NSColor.textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                Divider()
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Resume") { confirmResume() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedId == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color(NSColor.underPageBackgroundColor))
        }
    }

    // MARK: - Behavior

    private func confirmResume() {
        guard let id = selectedId else { return }
        let opts = ProcessManager.ResumeOptions(
            sessionId: id,
            forkSession: forkSession,
            displayName: nil,
            initialPrompt: initialPrompt
        )
        onResume(opts)
    }

    private func load() async {
        phase = .loading
        let cwd = task.cwd
        let result: Result<[ClaudeSessionService.SessionInfo], Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try ClaudeSessionService.scan(cwd: cwd))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .failure(let error):
            phase = .error(error.localizedDescription)
        case .success(let sessions):
            phase = sessions.isEmpty ? .empty : .loaded(sessions)
            if selectedId == nil, let first = sessions.first {
                selectedId = first.id
            }
        }
    }

    private func filteredSessions(in sessions: [ClaudeSessionService.SessionInfo]) -> [ClaudeSessionService.SessionInfo] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            $0.preview.lowercased().contains(q)
                || $0.id.uuidString.lowercased().contains(q)
        }
    }

    // MARK: - Formatting helpers

    private func relativeDate(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func humanSize(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
