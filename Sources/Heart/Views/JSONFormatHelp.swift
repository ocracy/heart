import SwiftUI
import AppKit

/// In-app reference for the heart.json schema. Shown from Settings, from the
/// "+ Add Project" menu, and from the empty-project / welcome placeholders so
/// users never have to leave the app to find docs. The top section deliberately
/// pushes "generate this with Claude" since hand-writing a bundle is rare —
/// most users paste the prompt into a Claude Code session in their project
/// directory and let the skill scan the repo.
struct JSONFormatHelp: View {
    let onClose: () -> Void
    @State private var promptCopied: Bool = false

    /// One-line instruction the user pastes into a `claude` session at the
    /// root of their project. The URL points at the canonical generator skill
    /// shipped in this repo so improvements ride along with the README.
    private let claudePrompt = """
Read https://raw.githubusercontent.com/ocracy/heart/refs/heads/main/heart-json-generator.md and generate a heart.json bundle for this project following that format. Save the file at the project root and tell me what you detected.
"""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sectionGenerateWithClaude
                    sectionShape
                    sectionTaskKinds
                    sectionFields
                    sectionExample
                    sectionTips
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 740, height: 680)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: "curlybraces")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("heart.json format")
                    .font(.system(size: 16, weight: .semibold))
                Text("Schema reference, full example, and a one-paste prompt to have Claude generate it for you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { onClose() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    // MARK: - Sections

    /// Top of the doc — pushed hardest because most heart.json files are
    /// auto-generated, not hand-written.
    private var sectionGenerateWithClaude: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.purple)
                Text("Don't write this by hand — let Claude do it")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Open a Claude Code session at your project root and paste the prompt below. Claude scans the repo (frontend dev servers, backend, queues, supporting daemons), picks SF Symbol icons, sets up quick actions for things like `npm install` / `optimize:clear`, and writes `heart.json` at the project root. Then drop that file onto Heart's tab bar.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            promptBlock
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.purple.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.25), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var promptBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(claudePrompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button {
                    copyPrompt()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: promptCopied ? "checkmark" : "doc.on.doc")
                        Text(promptCopied ? "Copied to clipboard" : "Copy prompt")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(promptCopied ? .green : .purple)
                .controlSize(.small)
            }
        }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(claudePrompt, forType: .string)
        withAnimation { promptCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { promptCopied = false }
        }
    }

    private var sectionShape: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Top-level shape")
            Text("Two shapes are accepted. The bundle shape is preferred — its `name` field becomes the project tab name on import.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            codeBlock("""
            // Preferred — bundle shape
            {
              "name": "My Project",
              "tasks": [ … ]
            }

            // Also accepted — bare task array (Heart will ask for a project name)
            [ … ]
            """)
        }
    }

    private var sectionTaskKinds: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Task kinds")
            Text("There are four kinds of tasks. The UI surfaces each differently — pick the right one for the job.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                kindRow(value: "(omit)",
                        iconName: "server.rack", tint: .blue,
                        title: "Service",
                        desc: "Long-running process. Play/stop buttons, status dot, port + URL chips.")
                kindRow(value: "\"shortcut\"",
                        iconName: "arrow.right.circle.fill", tint: .blue,
                        title: "Shortcut",
                        desc: "Generic command launcher — ssh, kubectl, db shells, log tailers. Plain sidebar row, no play/stop chrome. Click = run + open the terminal.")
                kindRow(value: "\"claude\"",
                        iconName: "sparkles", tint: .purple,
                        title: "Claude shortcut",
                        desc: "Pinned at the top of the sidebar. Each click opens a fresh terminal session — good for keeping multiple Claude chats in the same dir. Resume previous sessions via right-click.")
                kindRow(value: "\"quick\"",
                        iconName: "bolt.fill", tint: .orange,
                        title: "Quick action",
                        desc: "Compact chip above the sidebar. One click runs the command, one click stops. No port / URL. Built for migrations, cache busts, formatters.")
            }
        }
    }

    private var sectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Task fields")
            VStack(alignment: .leading, spacing: 8) {
                fieldRow("id", "string", required: false,
                         desc: "Stable identifier. Auto-generated (UUID) if missing. Reusing the same id across imports updates an existing task instead of creating a duplicate.")
                fieldRow("name", "string", required: false,
                         desc: "Display name in the sidebar. Optional if `icon` is set — Heart will render the icon alone.")
                fieldRow("command", "string", required: true,
                         desc: "Shell command. Runs in zsh -l -i (login + interactive) inside a PTY, so ~/.zshrc and ~/.zprofile are sourced.")
                fieldRow("cwd", "string", required: true,
                         desc: "Working directory. Tilde (~) is expanded.")
                fieldRow("kind", "enum", required: false,
                         desc: "Behavior tag — see Task kinds above. One of: `\"claude\"`, `\"shortcut\"`, `\"quick\"`. Omit for a regular service.")
                fieldRow("icon", "string", required: false,
                         desc: "SF Symbol name (e.g. `server.rack`, `bolt.fill`, `globe`). Lowercase + dotted. Renders next to the task name. Wrong / unknown names render blank — stick to real symbols.")
                fieldRow("port", "number", required: false,
                         desc: "TCP port the task binds (service kind only). Enables KILL PORT + readiness check (status stays Starting until the port is reachable).")
                fieldRow("url", "string", required: false,
                         desc: "Adds a Browser tab to the detail pane for this task — useful for local web servers. Service kind only.")
                fieldRow("folder", "string", required: false,
                         desc: "Sub-folder inside this project. Use \"/\" for nesting (e.g. \"Backend/Workers\"). When importing as a bundle the value nests under the bundle's name.")
                fieldRow("order", "number", required: false,
                         desc: "Manual sort key inside the folder — smaller renders first. You don't normally set this by hand; Heart's edit mode (⌘E) writes it when you reorder rows.")
                fieldRow("autoStart", "boolean", required: false,
                         desc: "Reserved — saved but not yet acted upon at launch time.")
            }
        }
    }

    private var sectionExample: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Full example — all four task kinds")
            codeBlock("""
            {
              "name": "My Shop",
              "tasks": [
                {
                  "id": "api",
                  "name": "API",
                  "command": "php artisan serve",
                  "cwd": "~/code/my-shop/api",
                  "folder": "Backend",
                  "icon": "server.rack",
                  "port": 8000,
                  "url": "http://localhost:8000"
                },
                {
                  "id": "queue",
                  "name": "Queue worker",
                  "command": "php artisan horizon",
                  "cwd": "~/code/my-shop/api",
                  "folder": "Backend",
                  "icon": "tray.full.fill"
                },
                {
                  "id": "web",
                  "name": "Web",
                  "command": "pnpm dev",
                  "cwd": "~/code/my-shop/web",
                  "folder": "Frontend",
                  "icon": "globe",
                  "port": 5173,
                  "url": "http://localhost:5173"
                },
                {
                  "id": "ssh-prod",
                  "name": "Prod SSH",
                  "command": "ssh deploy@my-shop.com",
                  "cwd": "~/code/my-shop",
                  "folder": "Ops",
                  "icon": "terminal",
                  "kind": "shortcut"
                },
                {
                  "id": "artisan-optimize",
                  "name": "Optimize",
                  "command": "php artisan optimize",
                  "cwd": "~/code/my-shop/api",
                  "folder": "Backend",
                  "icon": "bolt.fill",
                  "kind": "quick"
                },
                {
                  "id": "artisan-cache-clear",
                  "name": "Cache clear",
                  "command": "php artisan optimize:clear",
                  "cwd": "~/code/my-shop/api",
                  "folder": "Backend",
                  "icon": "trash",
                  "kind": "quick"
                },
                {
                  "id": "claude-root",
                  "name": "Claude (root)",
                  "command": "claude",
                  "cwd": "~/code/my-shop",
                  "kind": "claude"
                }
              ]
            }
            """)
        }
    }

    private var sectionTips: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Tips")
            VStack(alignment: .leading, spacing: 6) {
                tip("Dropping a JSON onto the tab bar creates a new project. Dropping it into the sidebar of an existing project replaces that project's tasks (with a confirm dialog).")
                tip("Heart remembers the source file path per project — when the in-memory state diverges from disk, an inline Save button appears next to the file name in the sidebar header.")
                tip("Right-click a Claude shortcut row → Resume previous session… to pick up an earlier conversation (history + cookies + branches preserved).")
                tip("Keep total `quick` actions per project small (≤ 5). The chip bar scrolls horizontally but is meant to be a short, scannable strip.")
                tip("Wrong / unknown SF Symbol names render as a blank space. Omit `icon` rather than guess.")
            }
        }
    }

    // MARK: - Atoms

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func kindRow(value: String,
                         iconName: String,
                         tint: Color,
                         title: String,
                         desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(tint.opacity(0.12))
                )
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.secondary.opacity(0.15))
                        )
                }
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ name: String, _ type: String, required: Bool, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(type)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if required {
                        Text("required")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.orange.opacity(0.18))
                            )
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            .frame(width: 160, alignment: .leading)
            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .font(.system(size: 11))
                .foregroundStyle(Color.yellow)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .textSelection(.enabled)
    }
}
