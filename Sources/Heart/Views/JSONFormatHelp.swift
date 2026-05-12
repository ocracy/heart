import SwiftUI
import AppKit

/// In-app reference for the heart.json schema. Shown from Settings ("?" button)
/// and the "+ Add Project" menu so users don't have to leave the app to find docs.
struct JSONFormatHelp: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    sectionShape
                    sectionFields
                    sectionExample
                    sectionTips
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Sections

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
                Text("Schema reference + example you can copy.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What it is")
                .font(.system(size: 13, weight: .semibold))
            Text("A heart.json file describes a project — a named group of tasks that Heart can start, stop, and monitor. Drop one onto the tab bar to add it as a new project, or drop it into an existing project's sidebar to replace its tasks.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var sectionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Task fields")
            VStack(alignment: .leading, spacing: 8) {
                fieldRow("id", "string", required: false,
                         desc: "Stable identifier. Auto-generated (UUID) if missing. Reusing the same id across imports updates an existing task instead of creating a duplicate.")
                fieldRow("name", "string", required: true,
                         desc: "Display name shown in the sidebar.")
                fieldRow("command", "string", required: true,
                         desc: "Shell command. Runs in zsh -l -i (login + interactive) inside a PTY, so ~/.zshrc and ~/.zprofile are sourced.")
                fieldRow("cwd", "string", required: true,
                         desc: "Working directory. Tilde (~) is expanded.")
                fieldRow("port", "number", required: false,
                         desc: "TCP port the task binds. Enables the KILL PORT button and a readiness check (status stays Starting until the port is reachable).")
                fieldRow("url", "string", required: false,
                         desc: "Adds a Browser tab to the detail pane for this task — useful for local web servers.")
                fieldRow("folder", "string", required: false,
                         desc: "Sub-folder inside this project. Use \"/\" for nesting (e.g. \"Backend/Workers\"). When importing as a bundle, this nests under the bundle's name.")
                fieldRow("autoStart", "boolean", required: false,
                         desc: "Reserved — saved but not yet acted upon at launch time.")
                fieldRow("kind", "string", required: false,
                         desc: "Behavior tag. \"claude\" pins the task at the top of the sidebar as a multi-session shortcut. \"quick\" surfaces it as a chip above the sidebar — one-shot run, no port / URL / status indicator. Omit (nil) for a regular long-running service.")
            }
        }
    }

    private var sectionExample: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Full example")
            codeBlock("""
            {
              "name": "My Stack",
              "tasks": [
                {
                  "id": "api",
                  "name": "API server",
                  "command": "npm run dev",
                  "cwd": "~/code/myapp/api",
                  "port": 3000,
                  "url": "http://localhost:3000",
                  "folder": "Backend"
                },
                {
                  "id": "worker",
                  "name": "Queue worker",
                  "command": "node worker.js",
                  "cwd": "~/code/myapp/api",
                  "folder": "Backend"
                },
                {
                  "id": "web",
                  "name": "Web app",
                  "command": "pnpm dev",
                  "cwd": "~/code/myapp/web",
                  "port": 5173,
                  "url": "http://localhost:5173",
                  "folder": "Frontend"
                },
                {
                  "id": "claude",
                  "name": "Claude in repo",
                  "command": "claude",
                  "cwd": "~/code/myapp",
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
                tip("Dropping a JSON onto the tab bar creates a new project. Dropping it into the sidebar of an existing project replaces that project's tasks.")
                tip("Heart remembers the source file path per project — right-click a tab → Save to overwrite it without picking a file again.")
                tip("Want a Claude Code shortcut per project? Set `kind: \"claude\"` — clicking the task opens a fresh terminal session each time, so you can keep multiple chats in the same dir.")
                tip("If `port` is set, Heart waits for the port to bind before marking the task Running. Tasks without a port go Running after a 1.5 s grace period.")
            }
        }
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

    // MARK: - Atoms

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
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
