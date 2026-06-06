import SwiftUI
import AppKit

/// Modal sheet for editing the cwds the detail-bar "+" → Terminal menu offers.
/// Reads and writes through `TaskStore` (which persists to
/// `terminal-shortcuts.json`), so the list is cross-project and survives
/// project deletions — same lifecycle as Browser bookmarks.
struct TerminalShortcutsSheet: View {
    @ObservedObject var store: TaskStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Terminal paths")
                    .font(.title2.bold())
                Spacer()
                Text("Saved cwds for the \"+ Terminal\" menu")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if store.terminalShortcuts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.terminalShortcuts) { shortcut in
                        row(for: shortcut)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    pickDirectory()
                } label: {
                    Label("Add path…", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No paths saved yet")
                .font(.headline)
            Text("Add a directory and it'll show up in the \"+ Terminal\" menu in the detail pane. Click an entry there to open a fresh terminal at that cwd.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func row(for shortcut: TerminalShortcut) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Label",
                          text: nameBinding(for: shortcut),
                          prompt: Text(shortcut.displayName))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                HStack(spacing: 4) {
                    Text(displayPath(shortcut.path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        rePick(shortcut: shortcut)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Change folder")
                }
            }

            Spacer()

            Button(role: .destructive) {
                store.removeTerminalShortcut(id: shortcut.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this path")
        }
        .padding(.vertical, 4)
    }

    private func nameBinding(for shortcut: TerminalShortcut) -> Binding<String> {
        Binding(
            get: { shortcut.name },
            set: { newValue in
                store.updateTerminalShortcut(id: shortcut.id,
                                             name: newValue,
                                             path: shortcut.path)
            }
        )
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as terminal path"
        if panel.runModal() == .OK, let url = panel.url {
            _ = store.addTerminalShortcut(name: url.lastPathComponent, path: url.path)
        }
    }

    private func rePick(shortcut: TerminalShortcut) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as terminal path"
        if panel.runModal() == .OK, let url = panel.url {
            store.updateTerminalShortcut(id: shortcut.id,
                                         name: shortcut.name,
                                         path: url.path)
        }
    }
}
