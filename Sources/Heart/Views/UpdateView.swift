import SwiftUI

/// Modal sheet shown when the user clicks the toolbar update button or when
/// the auto-check on launch discovers a newer release. Reflects every state
/// of `UpdateChecker` so the user always sees what's happening rather than
/// a dead modal.
struct UpdateView: View {
    @ObservedObject var checker: UpdateChecker
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(20)
            Divider()
            footer
        }
        .frame(width: 520)
        .frame(minHeight: 280)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerIcon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(headerTint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var headerIcon: String {
        switch checker.state {
        case .available:                return "arrow.down.circle.fill"
        case .downloading, .installing: return "arrow.down.circle"
        case .upToDate:                 return "checkmark.seal.fill"
        case .error:                    return "exclamationmark.triangle.fill"
        case .checking:                 return "arrow.triangle.2.circlepath"
        case .idle:                     return "arrow.down.circle"
        }
    }

    private var headerTint: Color {
        switch checker.state {
        case .available:    return .accentColor
        case .upToDate:     return .green
        case .error:        return .orange
        default:            return .secondary
        }
    }

    private var headerTitle: String {
        switch checker.state {
        case .available(let r):     return "Heart \(r.version) mevcut"
        case .downloading:          return "Güncelleme indiriliyor"
        case .installing:           return "Yeniden başlatılıyor"
        case .upToDate:             return "Heart güncel"
        case .checking:             return "Kontrol ediliyor"
        case .error:                return "Güncelleme hatası"
        case .idle:                 return "Güncellemeler"
        }
    }

    private var headerSubtitle: String {
        "Yüklü sürüm: \(checker.currentVersion)"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch checker.state {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("GitHub release'leri kontrol ediliyor…")
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .upToDate:
            Label("Çalıştırdığın sürüm en güncel olanı. Yeni bir release yayınlandığında burada görünecek.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)

        case .available(let release):
            availableContent(release: release)

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 10) {
                Text("Heart.zip indiriliyor…")
                    .font(.subheadline)
                ProgressView(value: progress)
                Text("%\(Int(progress * 100))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Yeni sürüm kuruluyor ve uygulama yeniden başlatılıyor…")
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("İnternet bağlantını kontrol et veya github.com/ocracy/heart adresinden manuel indir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func availableContent(release: UpdateChecker.Release) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(release.tag)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Text("• \(release.publishedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !release.notes.isEmpty {
                Text("Sürüm notları")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(release.notes)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch checker.state {
            case .available:
                Button("Daha Sonra", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await checker.downloadAndInstall() }
                } label: {
                    Label("Şimdi Güncelle", systemImage: "arrow.down.circle.fill")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

            case .downloading, .installing:
                Button("Kapat", action: onClose)
                    .disabled(true)

            case .error:
                Button("Kapat", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Tekrar Dene") {
                    Task { await checker.checkNow(userInitiated: true) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

            case .idle, .checking, .upToDate:
                Button("Tekrar Kontrol Et") {
                    Task { await checker.checkNow(userInitiated: true) }
                }
                Button("Kapat", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
