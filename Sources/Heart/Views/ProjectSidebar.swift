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
    /// A quick-action chip was tapped — toggle start/stop and select it for the
    /// detail pane.
    let onQuickTap: (DevTask) -> Void
    /// Create a blank quick-action task (opens the edit sheet pre-filled, kind=quick).
    let onAddQuickAction: () -> Void
    /// Create a new folder. Argument is the parent path; empty string means
    /// "at the project root" (callers should prepend the project name).
    let onAddFolder: (String) -> Void
    /// Rename a folder. Argument is the folder's absolute path.
    let onRenameFolder: (String) -> Void
    /// Move a task into a different folder. Second arg = new absolute path.
    let onMoveTask: (DevTask, String) -> Void
    /// Open the "Resume previous session…" picker for a Claude shortcut task.
    let onResumeClaude: (DevTask) -> Void
    /// True when the user toggled "Edit" in the toolbar. Surfaces drag handles
    /// so tasks + folders can be reordered.
    let editMode: Bool
    /// True when the linked source file is out of sync with the in-memory tasks.
    /// Drives the inline "Save" button in the SourceBar.
    let isDirty: Bool
    /// Save the project back to its linked source file.
    let onSaveSource: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            sourceBar
            quickActionsBar
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
                Text((path as NSString).lastPathComponent)
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
                if isDirty {
                    Button {
                        onSaveSource()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.down.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("Save")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Save unsaved changes to \((path as NSString).lastPathComponent)")
                }
            } else {
                Text("Not linked to a file · Save as… to link")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onAddFolder(project)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 10))
                    Text("Folder")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a folder to '\(project)'")
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

    // MARK: - Quick actions bar

    @ViewBuilder
    private var quickActionsBar: some View {
        let chips = store.quickActions(forProject: project)
        if !chips.isEmpty || true {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips) { task in
                            quickChip(for: task)
                        }
                    }
                    .padding(.leading, 8)
                }
                Button {
                    onAddQuickAction()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.accentColor.opacity(0.4),
                                    style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a quick-action chip")
                .padding(.trailing, 8)
            }
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.03))
        }
    }

    @ViewBuilder
    private func quickChip(for task: DevTask) -> some View {
        let isRunning = processManager.status(task.id).isRunning
        let isSelected = (selectedTaskId == task.id)
        Button {
            onQuickTap(task)
        } label: {
            HStack(spacing: 4) {
                let hasIcon = !(task.icon ?? "").isEmpty
                let hasName = !task.name.isEmpty
                if hasIcon {
                    Image(systemName: task.icon!)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isRunning ? Color.green : Color.accentColor)
                }
                if hasName {
                    Text(task.name)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !hasIcon {
                    // No identity at all — fall back to a placeholder so the
                    // chip still has tappable bulk.
                    Text("(unnamed)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isRunning
                          ? Color.green.opacity(0.18)
                          : (isSelected ? Color.accentColor.opacity(0.18)
                                        : Color.secondary.opacity(0.10)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isRunning
                            ? Color.green.opacity(0.55)
                            : (isSelected ? Color.accentColor.opacity(0.55)
                                          : Color.secondary.opacity(0.20)),
                            lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.command)
        .contextMenu {
            Button {
                onQuickTap(task)
            } label: {
                Label(isRunning ? "Stop" : "Run", systemImage: isRunning ? "stop.fill" : "play.fill")
            }
            Divider()
            Button { onEdit(task) } label: { Label("Edit…", systemImage: "pencil") }
            Button { onDuplicate(task) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) { onDelete(task) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
        HStack(spacing: 6) {
            if editMode {
                reorderStepper(
                    canUp: canMoveTask(task, by: -1),
                    canDown: canMoveTask(task, by: 1),
                    moveUp: { moveTask(task, by: -1) },
                    moveDown: { moveTask(task, by: 1) }
                )
            }
            if task.isClaudeShortcut {
                ClaudeShortcutRow(task: task, isSelected: selectedTaskId == task.id) {
                    selectedTaskId = task.id
                }
            } else {
                TaskRow(task: task,
                        processManager: processManager,
                        onShowBrowser: { onShowBrowser(task) })
            }
        }
        .tag(task.id)
        .contextMenu {
            if task.isClaudeShortcut { claudeRowMenu(for: task) }
            else { rowMenu(for: task) }
        }
    }

    /// Pair of up/down arrows used to reorder a row in edit mode. Cleaner than
    /// fighting List(selection:) over drag gestures.
    @ViewBuilder
    private func reorderStepper(canUp: Bool,
                                canDown: Bool,
                                moveUp: @escaping () -> Void,
                                moveDown: @escaping () -> Void) -> some View {
        VStack(spacing: 1) {
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(canUp ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 18, height: 11)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(canUp ? 0.10 : 0))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canUp)
            Button(action: moveDown) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(canDown ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 18, height: 11)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(canDown ? 0.10 : 0))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canDown)
        }
        .frame(width: 20)
    }

    // MARK: - Reorder via up/down steppers

    /// Tasks at the same direct folder, sorted by current `order` (nil last).
    private func taskSiblings(for task: DevTask) -> [DevTask] {
        guard let folder = task.folder else { return [] }
        return store.tasks
            .filter { $0.folder == folder && !$0.isQuickAction }
            .sorted { a, b in
                switch (a.order, b.order) {
                case let (l?, r?): return l < r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
    }

    private func canMoveTask(_ task: DevTask, by delta: Int) -> Bool {
        let siblings = taskSiblings(for: task)
        guard let idx = siblings.firstIndex(where: { $0.id == task.id }) else { return false }
        let new = idx + delta
        return new >= 0 && new < siblings.count
    }

    private func moveTask(_ task: DevTask, by delta: Int) {
        guard let folder = task.folder else { return }
        let siblings = taskSiblings(for: task)
        guard let idx = siblings.firstIndex(where: { $0.id == task.id }) else { return }
        let new = idx + delta
        guard new >= 0 && new < siblings.count else { return }
        var ids = siblings.map(\.id)
        ids.swapAt(idx, new)
        store.reorderTasks(inFolder: folder, taskIds: ids)
    }

    /// Sibling folder names sharing the same parent. Order is whatever the
    /// stored tree currently renders (already sorted by `folderOrder`).
    private func folderSiblings(of node: FolderNode) -> (parent: String, names: [String]) {
        let segments = node.path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return ("", []) }
        let parent = segments.dropLast().joined(separator: "/")
        let parentNode: FolderNode = {
            if parent.isEmpty {
                return store.buildTree()
            }
            let projectTree = store.buildTree(forProject: project)
            func walk(_ n: FolderNode) -> FolderNode? {
                if n.path == parent { return n }
                for s in n.subfolders { if let f = walk(s) { return f } }
                return nil
            }
            return walk(projectTree) ?? FolderNode(name: "", path: parent)
        }()
        return (parent, parentNode.subfolders.map(\.name))
    }

    private func canMoveFolder(_ node: FolderNode, by delta: Int) -> Bool {
        let (_, names) = folderSiblings(of: node)
        guard let idx = names.firstIndex(of: node.name) else { return false }
        let new = idx + delta
        return new >= 0 && new < names.count
    }

    private func moveFolder(_ node: FolderNode, by delta: Int) {
        let (parent, names) = folderSiblings(of: node)
        guard let idx = names.firstIndex(of: node.name) else { return }
        let new = idx + delta
        guard new >= 0 && new < names.count else { return }
        var next = names
        next.swapAt(idx, new)
        store.reorderSubfolders(parent: parent, names: next)
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
        moveToMenu(for: task)
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
        Button {
            onResumeClaude(task)
        } label: {
            Label("Resume previous session…", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        Button { onEdit(task) } label: { Label("Edit…", systemImage: "pencil") }
        moveToMenu(for: task)
        Button { onDuplicate(task) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) { onDelete(task) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func moveToMenu(for task: DevTask) -> some View {
        Menu {
            ForEach(availableFolderPaths, id: \.self) { path in
                Button {
                    onMoveTask(task, path)
                } label: {
                    if path == project {
                        Label("\(project) (root)", systemImage: "house")
                    } else {
                        let prefix = project + "/"
                        let display = path.hasPrefix(prefix)
                            ? String(path.dropFirst(prefix.count))
                            : path
                        Label(display, systemImage: "folder")
                    }
                }
                .disabled((task.folder ?? "") == path)
            }
            Divider()
            Button {
                onAddFolder(project)
            } label: {
                Label("New folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }
    }

    /// Project root + every subfolder path under it. Used to populate the
    /// per-row "Move to…" submenu.
    private var availableFolderPaths: [String] {
        var paths: [String] = [project]
        let root = store.buildTree(forProject: project)
        func walk(_ node: FolderNode) {
            if !node.path.isEmpty { paths.append(node.path) }
            for sub in node.subfolders { walk(sub) }
        }
        walk(root)
        return paths
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
            if editMode {
                reorderStepper(
                    canUp: canMoveFolder(node, by: -1),
                    canDown: canMoveFolder(node, by: 1),
                    moveUp: { moveFolder(node, by: -1) },
                    moveDown: { moveFolder(node, by: 1) }
                )
            }
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
            Button { onAddFolder(node.path) } label: {
                Label("Add subfolder…", systemImage: "folder.badge.plus")
            }
            Button { onRenameFolder(node.path) } label: {
                Label("Rename folder…", systemImage: "pencil")
            }
            Divider()
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
                Label(totalCount == 0
                      ? "Delete folder"
                      : "Delete folder (\(totalCount) tasks)",
                      systemImage: "trash")
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
