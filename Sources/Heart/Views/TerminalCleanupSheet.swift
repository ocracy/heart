import SwiftUI

/// Panel listing every live Heart tmux terminal (across the current and legacy
/// sockets) so the user can close leftovers / duplicates that accumulated over
/// time — individually or all-but-the-active-one in one click.
struct TerminalCleanupSheet: View {
    @ObservedObject var processManager: ProcessManager
    @Binding var isPresented: Bool
    /// The terminal the user is currently viewing — marked "aktif" and spared by
    /// "close all".
    let currentSessionId: String?

    @State private var sessions: [TmuxService.Managed] = []
    @State private var resumeCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminalleri Temizle").font(.headline)
                Spacer()
                Text("\(sessions.count) açık")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()

            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("Açık terminal yok").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sessions) { s in
                            row(s)
                            Divider()
                        }
                    }
                }
            }

            Divider()
            // Resume history — what the "+" dropdown lists as "Kapanmış terminaller".
            if resumeCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text("\(resumeCount) sürdürülebilir terminal (\"+\" listesinde)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Geçmişi temizle") {
                        processManager.clearResumeHistory()
                        reload()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            HStack {
                Button(role: .destructive) {
                    for s in sessions where s.name != currentSessionId {
                        processManager.killManaged(s)
                    }
                    processManager.clearResumeHistory()
                    reload()
                } label: {
                    Label("Aktif hariç her şeyi temizle", systemImage: "trash")
                }
                .disabled(sessions.allSatisfy { $0.name == currentSessionId } && resumeCount == 0)
                Spacer()
                Button("Bitti") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 420)
        .onAppear(perform: reload)
    }

    private func row(_ s: TmuxService.Managed) -> some View {
        let isCurrent = s.name == currentSessionId
        let legacy = s.socketArgs.contains("-L")
        let name = cleanTitle(s.title, fallback: "Terminal \(s.number)")
        return HStack(spacing: 10) {
            Circle()
                .fill(s.attached ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if isCurrent { tag("aktif", .green) }
                    if legacy { tag("eski", .orange) }
                }
                Text("\(s.task) · Terminal \(s.number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                processManager.killManaged(s)
                reload()
            } label: {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help(isCurrent ? "Şu an baktığın terminal — kapatırsan kopar" : "Bu terminali kapat")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// Strip Claude's leading status glyph; fall back to "Terminal N".
    private func cleanTitle(_ raw: String, fallback: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = s.first, !f.isLetter, !f.isNumber { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? fallback : s
    }

    private func reload() {
        sessions = processManager.managedSessions()
        resumeCount = processManager.resumeHistoryCount()
    }
}
