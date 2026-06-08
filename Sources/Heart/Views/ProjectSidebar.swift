import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Sidebar scoped to a single project. Renders the SourceBar (linked file path
/// or "Not linked") above the filtered folder tree. Drop here = replace this
/// project's tasks with the dropped bundle (confirmed by the parent).
struct ProjectSidebar: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var gitManager: GitManager

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
    /// Create a blank browser-kind task (opens edit sheet, kind=browser).
    let onAddBrowser: () -> Void
    /// Create a blank github-kind task (opens edit sheet, kind=github).
    let onAddGithub: () -> Void
    /// Instantiate the given bookmark as a browser task in the current project.
    let onPickBookmark: (Bookmark) -> Void
    /// Persist a browser task's current URL/name as a global bookmark.
    let onSaveBookmark: (DevTask) -> Void
    /// Remove a saved bookmark from the global library.
    let onDeleteBookmark: (Bookmark) -> Void
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
    /// Re-read the linked source file from disk and prompt the user to
    /// confirm overwrite. Surfaced from the sourceBar's filename menu.
    let onReloadSource: () -> Void

    @State private var isDropTargeted = false
    /// Folder path (sidebar header) currently being hovered with a dragged
    /// task. Used to outline the target so the drop affordance is visible —
    /// without it the user can't tell where their drag will land.
    @State private var dropHoverFolder: String?
    /// True while a task drag is hovering the sidebar's bottom "out of folder"
    /// zone. Drives that zone's accent outline.
    @State private var dropHoverRoot: Bool = false

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

            // Task-drag "leave folder" target — sits on top of the
            // JSON-import DropZone so dragging a row from inside a folder
            // out onto here moves it back to the project root. URL drops
            // (file imports) still pass through to the outer modifier on
            // the sidebar VStack via the `.dropDestination(for: URL.self)`
            // attached there; String drops (task ids) land here.
            DropZoneView(isTargeted: isDropTargeted)
                .padding(8)
                .overlay {
                    if dropHoverRoot {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                            .padding(8)
                    }
                }
                .onTapGesture { onPickImport() }
                .dropDestination(for: String.self) { ids, _ in
                    handleTaskDrop(ids, into: project)
                } isTargeted: { dropHoverRoot = $0 }
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
                Menu {
                    Button {
                        onReloadSource()
                    } label: {
                        Label("Reload from disk", systemImage: "arrow.clockwise")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                } label: {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(path)
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
            addBrowserControl
            addGithubControl
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
    }

    // MARK: - GitHub quick-add

    @ViewBuilder
    private var addGithubControl: some View {
        Button {
            onAddGithub()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10))
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Color.purple)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add a git repository to '\(project)'")
    }

    // MARK: - Browser quick-add

    /// "+ Browser" entry point. Plain button when no saved bookmarks exist
    /// (clicking opens a fresh edit sheet). Menu when bookmarks exist —
    /// listing them above "New URL…" so the user can pin a recurring URL
    /// once and add it to any project with one click.
    @ViewBuilder
    private var addBrowserControl: some View {
        let bookmarks = store.bookmarks
        if bookmarks.isEmpty {
            Button {
                onAddBrowser()
            } label: {
                addBrowserLabel
            }
            .buttonStyle(.plain)
            .help("Add a browser bookmark to '\(project)'")
        } else {
            Menu {
                Button {
                    onAddBrowser()
                } label: {
                    Label("New URL…", systemImage: "plus")
                }
                Divider()
                Section("Bookmarks") {
                    ForEach(bookmarks) { mark in
                        Menu {
                            Button {
                                onPickBookmark(mark)
                            } label: {
                                Label("Add to '\(project)'", systemImage: "plus")
                            }
                            Divider()
                            Button(role: .destructive) {
                                onDeleteBookmark(mark)
                            } label: {
                                Label("Remove from bookmarks", systemImage: "trash")
                            }
                        } label: {
                            Label(mark.name.isEmpty ? mark.url : mark.name,
                                  systemImage: mark.icon?.isEmpty == false ? mark.icon! : "globe")
                        }
                    }
                }
            } label: {
                addBrowserLabel
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a browser bookmark to '\(project)'")
        }
    }

    private var addBrowserLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: "globe")
                .font(.system(size: 10))
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Quick actions bar

    @ViewBuilder
    private var quickActionsBar: some View {
        let allChips = store.quickActions(forProject: project)
        let (rootChips, folderGroups) = partitionQuickChips(allChips)
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(rootChips) { task in
                        quickChip(for: task)
                    }
                    ForEach(folderGroups, id: \.folder) { group in
                        folderQuickChip(folder: group.folder, chips: group.chips)
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
        // Empty-area right-click on the quick bar. The chip buttons keep
        // their own contextMenu (Run/Stop/Move to/Edit/Duplicate/Delete);
        // SwiftUI picks the deepest hit-tested view, so right-clicking a
        // chip still shows the chip's menu — this only triggers between
        // chips or in the bar's empty trailing space.
        .contextMenu {
            Button { onAddQuickAction() } label: {
                Label("New quick action…", systemImage: "bolt.fill")
            }
            Button {
                onAddFolder(project)
            } label: {
                Label("New folder…", systemImage: "folder.badge.plus")
            }
        }
    }

    /// Split the project's quick chips into "lives at the project root" and
    /// "lives in a subfolder, grouped by folder name". Order inside each
    /// bucket follows the store's natural task order so users can rearrange
    /// chips by editing JSON / using ⌘E reorder.
    private func partitionQuickChips(_ chips: [DevTask])
        -> (root: [DevTask], folders: [(folder: String, chips: [DevTask])])
    {
        let prefix = project + "/"
        var root: [DevTask] = []
        var byFolder: [String: [DevTask]] = [:]
        var folderOrder: [String] = []
        for task in chips {
            let folderRaw = task.folder ?? ""
            let local: String
            if folderRaw.isEmpty || folderRaw == project {
                local = ""
            } else if folderRaw.hasPrefix(prefix) {
                local = String(folderRaw.dropFirst(prefix.count))
            } else {
                local = folderRaw
            }
            if local.isEmpty {
                root.append(task)
            } else {
                if byFolder[local] == nil { folderOrder.append(local) }
                byFolder[local, default: []].append(task)
            }
        }
        let folders = folderOrder.map { (folder: $0, chips: byFolder[$0] ?? []) }
        return (root, folders)
    }

    /// Folder-shaped chip that opens a dropdown showing every quick action
    /// stored inside that subfolder. Useful when the user has organized
    /// chips ("Backend", "Mobile") and doesn't want them flat across one row.
    @ViewBuilder
    private func folderQuickChip(folder: String, chips: [DevTask]) -> some View {
        let runningCount = chips.filter { processManager.status($0.id).isRunning }.count
        Menu {
            ForEach(chips) { task in
                Button {
                    onQuickTap(task)
                } label: {
                    let icon = (task.icon?.isEmpty == false) ? task.icon! : "bolt"
                    let label = task.name.isEmpty ? "(unnamed)" : task.name
                    Label(label, systemImage: icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(runningCount > 0 ? Color.green : Color.accentColor)
                Text(folderLeaf(folder))
                    .font(.system(size: 11))
                    .lineLimit(1)
                if runningCount > 0 {
                    Text("(\(runningCount))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.green)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(runningCount > 0
                          ? Color.green.opacity(0.18)
                          : Color.secondary.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(runningCount > 0
                            ? Color.green.opacity(0.55)
                            : Color.secondary.opacity(0.20),
                            lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(folder)
        // Drag a chip onto this folder chip = move that chip into this
        // folder. `folder` here is project-local ("Backend/Workers"); the
        // store wants an absolute path so we re-prefix with the project name.
        .dropDestination(for: String.self) { ids, _ in
            handleTaskDrop(ids, into: "\(project)/\(folder)")
        } isTargeted: { hovering in
            let key = "\(project)/\(folder)"
            dropHoverFolder = hovering ? key : (dropHoverFolder == key ? nil : dropHoverFolder)
        }
        .overlay {
            if dropHoverFolder == "\(project)/\(folder)" {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }

    /// Last path component of a "Frontend/Workers"-shaped folder string —
    /// the dropdown label stays compact even when the user nests chips deep.
    private func folderLeaf(_ folder: String) -> String {
        folder.split(separator: "/").last.map(String.init) ?? folder
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
        .draggable(task.id) {
            HStack(spacing: 4) {
                if let icon = task.icon, !icon.isEmpty {
                    Image(systemName: icon)
                }
                Text(task.name.isEmpty ? task.command : task.name)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.25))
            )
        }
        .contextMenu {
            Button {
                onQuickTap(task)
            } label: {
                Label(isRunning ? "Stop" : "Run", systemImage: isRunning ? "stop.fill" : "play.fill")
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
            } else if task.isShortcut {
                ShortcutRow(task: task,
                            isSelected: selectedTaskId == task.id,
                            processManager: processManager) {
                    if !processManager.status(task.id).isRunning {
                        processManager.start(task)
                    }
                    selectedTaskId = task.id
                }
            } else if task.isBrowser {
                BrowserRow(task: task,
                           isSelected: selectedTaskId == task.id) {
                    onShowBrowser(task)
                }
            } else if task.isGithub {
                GitHubRow(task: task,
                          isSelected: selectedTaskId == task.id,
                          gitManager: gitManager) {
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
            else if task.isShortcut { shortcutRowMenu(for: task) }
            else if task.isBrowser { browserRowMenu(for: task) }
            else if task.isGithub { githubRowMenu(for: task) }
            else { rowMenu(for: task) }
        }
        // Drag source: ship the task id as a plain string. Folder headers
        // and the sidebar's bottom "out of folder" zone are the destinations.
        // Quick action chips share the same id type, so a quick chip can be
        // dragged onto a folder chip too.
        .draggable(task.id) {
            HStack(spacing: 4) {
                if let icon = task.icon, !icon.isEmpty {
                    Image(systemName: icon)
                }
                Text(task.name.isEmpty ? task.command : task.name)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.25))
            )
        }
    }

    /// Common drop handler — shared by folder headers, the sidebar root
    /// drop zone, and the quick-bar folder chips. Looks the dragged id up
    /// in the store and calls `onMoveTask` when it actually changes folder;
    /// silently rejects no-ops (drag onto current folder, unknown id).
    private func handleTaskDrop(_ ids: [String], into folderPath: String) -> Bool {
        guard let id = ids.first,
              let task = store.tasks.first(where: { $0.id == id }) else {
            return false
        }
        if (task.folder ?? "") == folderPath { return false }
        onMoveTask(task, folderPath)
        return true
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
    private func shortcutRowMenu(for task: DevTask) -> some View {
        let isRunning = processManager.status(task.id).isRunning
        Button {
            if isRunning {
                processManager.stop(task)
            } else {
                processManager.start(task)
            }
        } label: {
            Label(isRunning ? "Stop" : "Run",
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
        Divider()
        Button(role: .destructive) { onDelete(task) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func browserRowMenu(for task: DevTask) -> some View {
        let urlString = task.url ?? ""
        Button {
            onShowBrowser(task)
        } label: {
            Label("Open in built-in browser", systemImage: "globe")
        }
        Button {
            TaskRow.openExternal(urlString)
        } label: {
            Label("Open in default browser", systemImage: "arrow.up.right.square")
        }
        .disabled(urlString.isEmpty)
        Divider()
        Button { onEdit(task) } label: { Label("Edit…", systemImage: "pencil") }
        moveToMenu(for: task)
        Button { onDuplicate(task) } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            onSaveBookmark(task)
        } label: {
            Label("Save as bookmark", systemImage: "bookmark")
        }
        .disabled(urlString.isEmpty)
        Divider()
        Button(role: .destructive) { onDelete(task) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func githubRowMenu(for task: DevTask) -> some View {
        Button {
            Task { await gitManager.refresh(taskId: task.id, cwd: task.cwd) }
        } label: {
            Label("Refresh status", systemImage: "arrow.clockwise")
        }
        Button {
            Task { await gitManager.pull(taskId: task.id, cwd: task.cwd) }
        } label: {
            Label("Pull (ff-only)", systemImage: "arrow.down.circle")
        }
        Button {
            Task { await gitManager.push(taskId: task.id, cwd: task.cwd) }
        } label: {
            Label("Push", systemImage: "arrow.up.circle")
        }
        Divider()
        Button {
            let expanded = GitManager.expand(task.cwd)
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: expanded)]
            )
        } label: {
            Label("Show in Finder", systemImage: "folder")
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
                        Label("At project root", systemImage: "arrow.up.to.line")
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
    /// per-row "Move to…" submenu. The walk visits root once (path == project)
    /// and every descendant — earlier code hardcoded `[project]` *and then*
    /// walked, producing two identical "root" entries in the menu.
    private var availableFolderPaths: [String] {
        var paths: [String] = []
        let root = store.buildTree(forProject: project)
        func walk(_ node: FolderNode) {
            paths.append(node.path)
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

            let runnableTasks = runnable(allTasks)
            if !runnableTasks.isEmpty {
                HStack(spacing: 6) {
                    folderIconButton(systemName: "play.fill", tint: .green,
                                     help: "Start all tasks in folder",
                                     enabled: hasStartable(allTasks)) {
                        processManager.startAll(runnableTasks)
                    }
                    folderIconButton(systemName: "stop.fill", tint: .red,
                                     help: "Stop all tasks in folder",
                                     enabled: hasStoppable(allTasks)) {
                        processManager.stopAll(runnableTasks)
                    }
                    folderIconButton(systemName: "arrow.clockwise", tint: .secondary,
                                     help: "Restart all tasks in folder",
                                     enabled: true) {
                        for task in runnableTasks { processManager.restart(task) }
                    }
                }
                .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, CGFloat(depth * 14))
        .padding(.trailing, 6)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(dropHoverFolder == node.path ? Color.accentColor : .clear,
                        lineWidth: 1.5)
                .padding(.horizontal, 4)
        )
        .dropDestination(for: String.self) { ids, _ in
            handleTaskDrop(ids, into: node.path)
        } isTargeted: { hovering in
            dropHoverFolder = hovering ? node.path : (dropHoverFolder == node.path ? nil : dropHoverFolder)
        }
        .contextMenu {
            Button { onAddFolder(node.path) } label: {
                Label("Add subfolder…", systemImage: "folder.badge.plus")
            }
            Button { onRenameFolder(node.path) } label: {
                Label("Rename folder…", systemImage: "pencil")
            }
            let runnableTasks = runnable(allTasks)
            if !runnableTasks.isEmpty {
                Divider()
                Button { processManager.startAll(runnableTasks) } label: {
                    Label("Start all", systemImage: "play.fill")
                }.disabled(!hasStartable(allTasks))
                Button { processManager.stopAll(runnableTasks) } label: {
                    Label("Stop all", systemImage: "stop.fill")
                }.disabled(!hasStoppable(allTasks))
                Button { for task in runnableTasks { processManager.restart(task) } } label: {
                    Label("Restart all", systemImage: "arrow.clockwise")
                }
            }
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
        runnable(tasks).contains { !processManager.status($0.id).isRunning }
    }
    private func hasStoppable(_ tasks: [DevTask]) -> Bool {
        runnable(tasks).contains { processManager.status($0.id).isRunning }
    }

    /// Tasks the folder header's start/stop/restart buttons should act on.
    /// Excludes kinds that never spawn a process (browser bookmarks, github
    /// repo panels) — without this filter the buttons would render on a folder
    /// of repos with nothing useful to do.
    private func runnable(_ tasks: [DevTask]) -> [DevTask] {
        tasks.filter { !$0.isBrowser && !$0.isGithub }
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
