import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sidebar scoped to a single project. Renders the SourceBar (linked file path
/// or "Not linked") above the filtered folder tree. Drop here = replace this
/// project's tasks with the dropped bundle (confirmed by the parent).
struct ProjectSidebar: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var processManager: ProcessManager

    /// Currently active project. `nil` (no projects yet) is handled by the parent
    /// (welcome screen); this view assumes a non-nil value.
    let project: String
    @Binding var selectedTaskId: String?
    @Binding var collapsedFolders: Set<String>

    let onEdit: (DevTask) -> Void
    let onDelete: (DevTask) -> Void
    let onDuplicate: (DevTask) -> Void
    let onOpenClaudeHere: (DevTask) -> Void
    let onShowBrowser: (DevTask) -> Void

    let onSaveBundle: (_ folderPath: String, _ filePath: String) -> Void
    let onExportBundle: (_ folderPath: String) -> Void
    let onDeleteFolder: (_ folderPath: String) -> Void

    /// JSON dropped onto this sidebar — parent should ask the user to confirm
    /// replacing the current project's tasks with the dropped bundle.
    let onDropReplace: ([URL]) -> Void
    /// "Drop or click to import" affordance at the bottom — open file picker.
    let onPickImport: () -> Void
    /// Create a blank task in this project (opens the edit sheet pre-filled).
    let onAddTask: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            sourceBar
            Divider()
            List(selection: $selectedTaskId) {
                let root = store.buildTree(forProject: project)
                ForEach(root.tasks) { task in
                    sidebarRow(task: task)
                }
                ForEach(root.subfolders, id: \.path) { node in
                    folderTree(node: node, depth: 0)
                }
            }
            .listStyle(.sidebar)

            DropZoneView(isTargeted: isDropTargeted)
                .padding(8)
                .onTapGesture { onPickImport() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDropReplace(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                replaceOverlay
            }
        }
    }

    // MARK: - SourceBar

    @ViewBuilder
    private var sourceBar: some View {
        let path = store.bundleSource(forFolder: project)
        HStack(spacing: 6) {
            Image(systemName: path != nil ? "doc.text.fill" : "link.badge.plus")
                .font(.system(size: 10))
                .foregroundStyle(path != nil ? Color.accentColor : .secondary)
            if let path {
                Text(displayPath(path))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(path)
                    .onTapGesture {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    }
            } else {
                Text("Not linked to a file · Save as… to link")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onAddTask()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text("Task")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a task to '\(project)'")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Rows

    @ViewBuilder
    private func sidebarRow(task: DevTask) -> some View {
        if task.isClaudeShortcut {
            ClaudeShortcutRow(task: task, isSelected: selectedTaskId == task.id) {
                selectedTaskId = task.id
            }
            .tag(task.id)
            .contextMenu { claudeRowMenu(for: task) }
        } else {
            TaskRow(task: task,
                    processManager: processManager,
                    onShowBrowser: { onShowBrowser(task) })
                .tag(task.id)
                .contextMenu { rowMenu(for: task) }
        }
    }

    @ViewBuilder
    private func rowMenu(for task: DevTask) -> some View {
        let isRunning = processManager.status(task.id).isRunning
        Button { processManager.toggle(task) } label: {
            Label(isRunning ? "Stop" : "Start",
                  systemImage: isRunning ? "stop.fill" : "play.fill")
        }
        Button { processManager.restart(task) } label: {
            Label("Restart", systemImage: "arrow.clockwise")
        }
        Divider()
        Button { onEdit(task) } label: { Label("Edit…", systemImage: "pencil") }
        Button { onDuplicate(task) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button { onOpenClaudeHere(task) } label: {
            Label("Open Claude Here", systemImage: "sparkles")
        }
        Divider()
        Button(role: .destructive) { onDelete(task) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func claudeRowMenu(for task: DevTask) -> some View {
        Button { onEdit(task) } label: { Label("Edit…", systemImage: "pencil") }
        Button { onDuplicate(task) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) { onDelete(task) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Folder tree

    private func folderTree(node: FolderNode, depth: Int) -> AnyView {
        let isCollapsed = collapsedFolders.contains(node.path)
        let allTasks = node.allTasks()
        let runningCount = allTasks.filter { processManager.status($0.id).isRunning }.count

        return AnyView(
            Group {
                folderHeader(node: node,
                             depth: depth,
                             isCollapsed: isCollapsed,
                             runningCount: runningCount,
                             totalCount: allTasks.count,
                             allTasks: allTasks)
                if !isCollapsed {
                    ForEach(node.tasks) { task in
                        sidebarRow(task: task)
                            .padding(.leading, CGFloat((depth + 1) * 14))
                    }
                    ForEach(node.subfolders, id: \.path) { sub in
                        folderTree(node: sub, depth: depth + 1)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func folderHeader(node: FolderNode,
                              depth: Int,
                              isCollapsed: Bool,
                              runningCount: Int,
                              totalCount: Int,
                              allTasks: [DevTask]) -> some View {
        HStack(spacing: 12) {
            Button {
                if collapsedFolders.contains(node.path) {
                    collapsedFolders.remove(node.path)
                } else {
                    collapsedFolders.insert(node.path)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tint)
                    Text(node.name)
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(verbatim: "(\(runningCount)/\(totalCount))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(runningCount > 0 ? Color.green : Color.secondary.opacity(0.6))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                folderIconButton(systemName: "play.fill", tint: .green,
                                 help: "Start all tasks in folder",
                                 enabled: hasStartable(allTasks)) {
                    processManager.startAll(allTasks)
                }
                folderIconButton(systemName: "stop.fill", tint: .red,
                                 help: "Stop all tasks in folder",
                                 enabled: hasStoppable(allTasks)) {
                    processManager.stopAll(allTasks)
                }
                folderIconButton(systemName: "arrow.clockwise", tint: .secondary,
                                 help: "Restart all tasks in folder",
                                 enabled: !allTasks.isEmpty) {
                    for task in allTasks { processManager.restart(task) }
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(depth * 14))
        .padding(.trailing, 6)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .contextMenu {
            Button { processManager.startAll(allTasks) } label: {
                Label("Start all", systemImage: "play.fill")
            }.disabled(!hasStartable(allTasks))
            Button { processManager.stopAll(allTasks) } label: {
                Label("Stop all", systemImage: "stop.fill")
            }.disabled(!hasStoppable(allTasks))
            Button { for task in allTasks { processManager.restart(task) } } label: {
                Label("Restart all", systemImage: "arrow.clockwise")
            }.disabled(allTasks.isEmpty)
            Divider()
            if let sourcePath = store.bundleSource(forFolder: node.path) {
                Button {
                    onSaveBundle(node.path, sourcePath)
                } label: {
                    Label("Save to \((sourcePath as NSString).lastPathComponent)",
                          systemImage: "square.and.arrow.down")
                }
            }
            Button { onExportBundle(node.path) } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }.disabled(allTasks.isEmpty)
            Divider()
            Button(role: .destructive) { onDeleteFolder(node.path) } label: {
                Label("Delete folder (\(totalCount) tasks)", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func folderIconButton(systemName: String,
                                  tint: Color,
                                  help: String,
                                  enabled: Bool = true,
                                  action: @escaping () -> Void) -> some View {
        let activeTint = enabled ? tint : Color.secondary.opacity(0.5)
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activeTint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(activeTint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(activeTint.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.55)
    }

    private func hasStartable(_ tasks: [DevTask]) -> Bool {
        tasks.contains { !processManager.status($0.id).isRunning }
    }
    private func hasStoppable(_ tasks: [DevTask]) -> Bool {
        tasks.contains { processManager.status($0.id).isRunning }
    }

    // MARK: - Drop overlay

    @ViewBuilder
    private var replaceOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 36, weight: .light))
                Text("Drop to replace '\(project)'")
                    .font(.system(size: 14, weight: .semibold))
                Text("Existing tasks of this project will be replaced.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.accentColor)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
        }
        .allowsHitTesting(false)
    }
}
