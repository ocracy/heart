import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var jsonText: String = ""
    @State private var errorMessage: String?
    @State private var showFormatHelp = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Tasks (JSON)")
                    .font(.title2.bold())
                Button {
                    showFormatHelp = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "questionmark.circle")
                        Text("Format help")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show heart.json schema reference")
                Spacer()
                Text(store.configPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding()

            Divider()

            JSONEditor(text: $jsonText)
                .padding(8)
                .background(Color(NSColor.textBackgroundColor))

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(size: 11, design: .monospaced))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
            }

            Divider()

            HStack(spacing: 8) {
                Button("Import…") { importJSON() }
                Button("Export…") { exportJSON() }
                Button("Open in Finder") { openInFinder() }
                Button("Reset to Defaults") { resetToDefaults() }
                    .foregroundStyle(.red)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save & Close") { saveAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            jsonText = encode(store.tasks)
        }
        .sheet(isPresented: $showFormatHelp) {
            JSONFormatHelp(onClose: { showFormatHelp = false })
        }
    }

    // MARK: - actions

    private func saveAndClose() {
        let result = decode(jsonText)
        if let tasks = result.tasks {
            store.update(tasks)
            errorMessage = nil
            dismiss()
        } else {
            errorMessage = result.error
        }
    }

    private func resetToDefaults() {
        jsonText = encode(TaskStore.defaults)
        errorMessage = nil
    }

    private func openInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.configPath)])
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url),
           let str = String(data: data, encoding: .utf8) {
            jsonText = str
            errorMessage = decode(str).error
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "tasks.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? jsonText.data(using: .utf8)?.write(to: url)
        }
    }

    // MARK: - encode/decode

    private func encode(_ tasks: [DevTask]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks),
              let str = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return str
    }

    private func decode(_ str: String) -> (tasks: [DevTask]?, error: String?) {
        guard let data = str.data(using: .utf8) else {
            return (nil, "Invalid UTF-8")
        }
        do {
            let tasks = try JSONDecoder().decode([DevTask].self, from: data)
            let cleaned = tasks.filter {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
                !$0.command.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return (cleaned, nil)
        } catch let DecodingError.dataCorrupted(ctx) {
            return (nil, "JSON parse error: \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, ctx) {
            return (nil, "Missing key '\(key.stringValue)' at \(ctx.codingPath)")
        } catch let DecodingError.typeMismatch(_, ctx) {
            return (nil, "Type mismatch at \(ctx.codingPath): \(ctx.debugDescription)")
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

private struct JSONEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        if let tv = scroll.documentView as? NSTextView {
            tv.isRichText = false
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.allowsUndo = true
            tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.delegate = context.coordinator
            tv.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { self._text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}
