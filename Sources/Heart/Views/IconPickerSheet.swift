import SwiftUI
import AppKit

/// Curated SF Symbol picker for assigning icons to tasks. We hand-curate a list
/// (vs. shipping the full SF Symbols catalog) because the catalog has thousands
/// of entries — most irrelevant for dev-task icons. Users can still type any SF
/// Symbol name in the search bar; if it matches a known symbol it'll preview.
struct IconPickerSheet: View {
    let current: String?
    let onCancel: () -> Void
    let onPick: (String?) -> Void

    @State private var query: String = ""
    @State private var customName: String = ""

    private static let columns: [GridItem] = Array(
        repeating: GridItem(.fixed(44), spacing: 6),
        count: 9
    )

    /// Curated set, grouped by intent. Order within each group is intentional.
    private static let icons: [String] = [
        // Process / runtime
        "play.fill", "stop.fill", "pause.fill", "arrow.clockwise",
        "arrow.triangle.2.circlepath", "power", "bolt.fill", "sparkles",
        // Servers / network
        "server.rack", "network", "wifi", "antenna.radiowaves.left.and.right",
        "externaldrive", "internaldrive", "cylinder.split.1x2",
        "cloud", "icloud", "globe",
        // Code / tools
        "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "hammer.fill", "wrench.adjustable.fill", "screwdriver.fill",
        "command", "gearshape.fill", "slider.horizontal.3",
        // Files / data
        "doc.fill", "doc.text.fill", "folder.fill", "archivebox.fill",
        "shippingbox.fill", "cube.fill", "square.stack.3d.up.fill",
        "tray.fill", "tray.full.fill",
        // Web / link
        "safari.fill", "link", "bookmark.fill", "tag.fill",
        "magnifyingglass", "eye.fill",
        // Status
        "checkmark.circle.fill", "exclamationmark.triangle.fill",
        "xmark.circle.fill", "info.circle.fill", "questionmark.circle.fill",
        "flag.fill", "star.fill", "heart.fill",
        // AI / brain
        "brain.head.profile", "brain", "cpu.fill", "memorychip.fill",
        // Media / comm
        "envelope.fill", "paperplane.fill", "message.fill", "bubble.left.fill",
        "phone.fill", "video.fill", "mic.fill", "camera.fill",
        "music.note", "speaker.wave.2.fill", "play.rectangle.fill",
        // Devices
        "laptopcomputer", "desktopcomputer", "macbook", "iphone", "ipad",
        "applewatch", "headphones",
        // Charts / metrics
        "chart.bar.fill", "chart.line.uptrend.xyaxis", "chart.pie.fill",
        "gauge.with.dots.needle.50percent", "speedometer",
        // People / org
        "person.fill", "person.2.fill", "person.3.fill",
        "building.2.fill", "house.fill", "lock.fill", "key.fill",
        // Misc fun
        "leaf.fill", "flame.fill", "drop.fill", "snowflake",
        "moon.fill", "sun.max.fill", "paintbrush.fill",
        "gamecontroller.fill", "trophy.fill"
    ]

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Self.icons }
        return Self.icons.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchAndCustom
            Divider()
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 6) {
                    ForEach(filtered, id: \.self) { name in
                        iconButton(name)
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 540)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { customName = current ?? "" }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: current ?? "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose icon")
                    .font(.system(size: 16, weight: .semibold))
                Text(current ?? "No icon set")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if current != nil {
                Button(role: .destructive) {
                    onPick(nil)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var searchAndCustom: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter (e.g. \"play\", \"folder\")", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func iconButton(_ name: String) -> some View {
        let isCurrent = (current == name)
        Button {
            onPick(name)
        } label: {
            Image(systemName: name)
                .font(.system(size: 18))
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isCurrent
                              ? Color.accentColor.opacity(0.18)
                              : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isCurrent
                                ? Color.accentColor.opacity(0.55)
                                : Color.secondary.opacity(0.15),
                                lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Or type:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("SF Symbol name", text: $customName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: 180)
                if !customName.isEmpty {
                    Image(systemName: customName)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )

            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Use custom") {
                let trimmed = customName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                onPick(trimmed)
            }
            .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty
                      || customName == (current ?? ""))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.underPageBackgroundColor))
    }
}
