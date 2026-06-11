import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DetailTab: String, CaseIterable, Hashable {
    case terminal
    case browser
    case github

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .github:   return "Git"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .github:  return "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var processManager: ProcessManager
    @ObservedObject var browserManager: BrowserManager
    @ObservedObject var gitManager: GitManager
    /// Routes external file URLs (Finder/dock drops, "open with…") into this
    /// window. Without it, dropped JSONs spawn a new blank window.
    @ObservedObject var router: ContentRouter
    @ObservedObject private var updateChecker = UpdateChecker.shared

    @State private var selectedProject: String?
    /// Per-project memory of the last selected task. Restored when switching tabs.
    @State private var selectedTaskByProject: [String: String] = [:]
    @State private var selectedTaskId: String?
    /// Last selectedTaskId we know matched a real task. Used to bounce back when
    /// macOS List selection lands on a folder header — see `.onChange(of:)` below.
    @State private var lastValidTaskId: String?
    @State private var showSettings = false
    @State private var collapsedFolders: Set<String> = []
    @State private var pendingImport: PendingImport?
    @State private var pendingReplace: PendingReplace?
    @State private var renameTarget: RenameRequest?
    @State private var editingTask: DevTask?
    @State private var importError: String?
    @State private var importToast: String?
    @State private var activeTabs: [String: DetailTab] = [:]
    /// Drives the native macOS sidebar toggle in the window title bar.
    /// Was pinned to `.constant(.all)` historically because of a SwiftUI bug
    /// that auto-collapsed the column on selection changes; that behavior is
    /// no longer reproducible in macOS 13.3+, so we let the user control it.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Pending project to delete (with confirm dialog).
    @State private var deleteProjectTarget: String?
    @State private var showFormatHelp = false
    @State private var addFolderTarget: AddFolderRequest?
    @State private var renameFolderTarget: RenameFolderRequest?
    @State private var resumeClaudeTarget: DevTask?
    /// Toggled by the detail-bar "+" → "Manage paths…" entry. Drives a sheet
    /// where the user can rename / re-target / delete saved terminal cwds.
    @State private var showTerminalShortcuts = false
    /// Toggled by the "Edit" toolbar button. When on, the sidebar surfaces
    /// drag handles so the user can reorder tasks + folders. Off by default
    /// so the normal view stays uncluttered.
    @State private var editMode: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if !store.orderedProjects.isEmpty {
                ProjectTabBar(
                    projects: store.orderedProjects,
                    selection: $selectedProject,
                    runningCounts: runningCountsByProject,
                    sources: store.bundleSources,
                    onSelect: { switchToProject($0) },
                    onPickFile: { pickAndImport(into: nil) },
                    onCreateEmpty: createEmptyProject,
                    onShowFormatHelp: { showFormatHelp = true },
                    onDropNewProject: { urls in handleDroppedURLs(urls, into: nil) },
                    onDropOntoProject: { project, urls in handleDroppedURLs(urls, into: project) },
                    onReorder: { store.reorderProjects($0) },
                    onRename: { renameTarget = RenameRequest(currentName: $0) },
                    onSave: { saveProject($0) },
                    onSaveAs: { saveProjectAs($0) },
                    onUnlinkSource: { store.unlinkSource(project: $0) },
                    onExport: { exportBundle(folderPath: $0) },
                    onStartAll: { processManager.startAll(store.tasksUnder(project: $0)) },
                    onStopAll: { processManager.stopAll(store.tasksUnder(project: $0)) },
                    onRestartAll: { project in
                        for task in store.tasksUnder(project: project) {
                            processManager.restart(task)
                        }
                    },
                    onDelete: { deleteProjectTarget = $0 }
                )
            }
            mainPane
        }
        .toolbar { toolbarItems }
        .sheet(isPresented: $showSettings) {
            if let project = selectedProject {
                SettingsView(store: store, project: project)
            }
        }
        .onReceive(router.$pendingImportURLs) { urls in
            guard !urls.isEmpty else { return }
            // Drain the queue before processing so re-entrant onReceive doesn't
            // re-import the same URLs.
            router.pendingImportURLs = []
            for url in urls { presentImport(for: url) }
        }
        .sheet(isPresented: $updateChecker.sheetPresented) {
            UpdateView(checker: updateChecker, onClose: { updateChecker.sheetPresented = false })
        }
        .sheet(isPresented: $showFormatHelp) {
            JSONFormatHelp(onClose: { showFormatHelp = false })
        }
        .sheet(isPresented: $showTerminalShortcuts) {
            TerminalShortcutsSheet(store: store,
                                   onClose: { showTerminalShortcuts = false })
        }
        .sheet(item: $addFolderTarget) { req in
            AddFolderPrompt(
                parent: req.parent,
                onCancel: { addFolderTarget = nil },
                onConfirm: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { addFolderTarget = nil; return }
                    let full = req.parent.isEmpty ? trimmed : "\(req.parent)/\(trimmed)"
                    store.addFolder(path: full)
                    addFolderTarget = nil
                }
            )
        }
        .sheet(item: $resumeClaudeTarget) { task in
            ClaudeResumeSheet(
                task: task,
                onCancel: { resumeClaudeTarget = nil },
                onResume: { options in
                    processManager.resumeSession(for: task, options: options)
                    selectedTaskId = task.id
                    resumeClaudeTarget = nil
                }
            )
        }
        .sheet(item: $renameFolderTarget) { req in
            RenameFolderPrompt(
                currentPath: req.path,
                onCancel: { renameFolderTarget = nil },
                onConfirm: { newName in
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { renameFolderTarget = nil; return }
                    let parts = req.path.split(separator: "/").map(String.init)
                    let parent = parts.dropLast().joined(separator: "/")
                    let newFull = parent.isEmpty ? trimmed : "\(parent)/\(trimmed)"
                    store.renameFolder(oldPath: req.path, newPath: newFull)
                    renameFolderTarget = nil
                }
            )
        }
        .sheet(item: $pendingImport) { pending in
            ImportFolderPrompt(
                pending: pending,
                onCancel: { pendingImport = nil },
                onConfirm: { folder in
                    store.append(pending.tasks, folder: folder)
                    if let source = pending.sourcePath {
                        store.setBundleSource(folder: folder, path: source)
                    }
                    processManager.scanForExternalServices(store.tasksUnder(path: folder))
                    importToast = "Imported \(pending.tasks.count) task\(pending.tasks.count == 1 ? "" : "s") into '\(folder)'"
                    pendingImport = nil
                    switchToProject(folder)
                }
            )
        }
        .sheet(item: $renameTarget) { req in
            RenameProjectPrompt(
                currentName: req.currentName,
                onCancel: { renameTarget = nil },
                onConfirm: { newName in
                    let finalName = store.renameProject(req.currentName, to: newName)
                    if selectedProject == req.currentName {
                        selectedProject = finalName
                    }
                    if let taskId = selectedTaskByProject.removeValue(forKey: req.currentName) {
                        selectedTaskByProject[finalName] = taskId
                    }
                    renameTarget = nil
                }
            )
        }
        .sheet(item: $editingTask) { task in
            EditTaskSheet(
                task: task,
                onCancel: { editingTask = nil },
                onSave: { updated in
                    let wasRunning = processManager.status(updated.id).isRunning
                    if wasRunning && (updated.command != task.command || updated.cwd != task.cwd) {
                        processManager.stop(task)
                    }
                    store.upsert(updated)
                    editingTask = nil
                }
            )
        }
        .alert(
            "Replace tasks?",
            isPresented: Binding(
                get: { pendingReplace != nil },
                set: { if !$0 { pendingReplace = nil } }
            ),
            presenting: pendingReplace
        ) { req in
            Button("Cancel", role: .cancel) { pendingReplace = nil }
            Button("Replace", role: .destructive) {
                if let req = pendingReplace {
                    performReplace(req)
                }
                pendingReplace = nil
            }
        } message: { req in
            if let summary = req.diffSummary {
                Text("Reload '\(req.project)' from \(req.sourceURL.lastPathComponent)?\n\(summary)\nThis will overwrite all tasks in this project.")
            } else {
                Text("Replace tasks of '\(req.project)' with contents of \(req.sourceURL.lastPathComponent)?\nThis will overwrite all tasks in this project.")
            }
        }
        .alert(
            "Delete project?",
            isPresented: Binding(
                get: { deleteProjectTarget != nil },
                set: { if !$0 { deleteProjectTarget = nil } }
            ),
            presenting: deleteProjectTarget
        ) { name in
            Button("Cancel", role: .cancel) { deleteProjectTarget = nil }
            Button("Delete", role: .destructive) {
                if let name = deleteProjectTarget {
                    performDeleteProject(name)
                }
                deleteProjectTarget = nil
            }
        } message: { name in
            let count = store.tasksUnder(project: name).count
            Text("Delete '\(name)' and \(count) task\(count == 1 ? "" : "s")?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .heartSelectSlot)) { note in
            guard let slot = note.object as? Int else { return }
            handleSlotShortcut(slot)
        }
        .onAppear {
            NSLog("[Heart] ContentView onAppear — %d task(s), %d project(s)",
                  store.tasks.count, store.orderedProjects.count)
            if selectedProject == nil {
                selectedProject = store.orderedProjects.first
            }
            if let project = selectedProject {
                let firstTask = store.tasksUnder(project: project).first?.id
                selectedTaskId = selectedTaskByProject[project] ?? firstTask
                lastValidTaskId = selectedTaskId
            }
            processManager.scanForExternalServices(store.tasks)
        }
        .onChange(of: selectedTaskId) { newId in
            guard let newId else { return }
            if store.tasks.contains(where: { $0.id == newId }) {
                lastValidTaskId = newId
                if let project = selectedProject {
                    selectedTaskByProject[project] = newId
                }
                // Auto-recovery for the Claude render glitch: after the
                // detail pane has had a beat to relayout, force a full
                // repaint on the freshly-shown task. This is the same
                // operation as the toolbar Repaint button — the user
                // observed that switching tabs "sometimes fixed it",
                // because attach() already triggers a refresh; this makes
                // the recovery deterministic instead of accidental.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [newId] in
                    processManager.repaint(newId)
                }
            } else {
                DispatchQueue.main.async {
                    selectedTaskId = lastValidTaskId
                }
            }
        }
        .onChange(of: store.orderedProjects) { projects in
            // Project deleted (e.g. via Settings JSON edit) — fall back to first.
            if let cur = selectedProject, !projects.contains(cur) {
                selectedProject = projects.first
                if let p = selectedProject {
                    selectedTaskId = selectedTaskByProject[p]
                        ?? store.tasksUnder(project: p).first?.id
                } else {
                    selectedTaskId = nil
                }
            }
            // If we just lost all projects, recreate the default so the UI is never empty.
            if projects.isEmpty {
                let name = store.createEmptyProject(suggestedName: TaskStore.defaultProjectName)
                selectedProject = name
            }
        }
        .alert("Import failed",
               isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
               ),
               actions: { Button("OK") { importError = nil } },
               message: { Text(importError ?? "") })
        .overlay(alignment: .top) {
            if let toast = importToast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: importToast)
        .onChange(of: importToast) { newValue in
            guard let value = newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if importToast == value { importToast = nil }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // `.primaryAction` pins the group to the right end of the title bar.
        // Without it macOS spreads the items to fill the center, which looked
        // like our buttons were "floating in the middle".
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                editMode.toggle()
            } label: {
                Label(editMode ? "Done" : "Edit",
                      systemImage: editMode ? "checkmark.circle.fill" : "pencil")
            }
            .help(editMode
                  ? "Exit edit mode"
                  : "Edit mode — reorder tasks and folders")
            .keyboardShortcut("e", modifiers: [.command])

            Button {
                if let project = selectedProject {
                    processManager.startAll(store.tasksUnder(project: project))
                }
            } label: {
                Label("Start All", systemImage: "play.circle.fill")
            }
            .help("Start every task in the current project")
            .disabled(!hasStartable(currentProjectTasks))

            Button {
                if let project = selectedProject {
                    processManager.stopAll(store.tasksUnder(project: project))
                }
            } label: {
                Label("Stop All", systemImage: "stop.circle.fill")
            }
            .help("Stop every task in the current project")
            .disabled(!hasStoppable(currentProjectTasks))

            Spacer()

            updateToolbarButton

            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help(selectedProject.map { "Edit '\($0)' tasks" } ?? "Select a project first")
            .disabled(selectedProject == nil)
        }
    }

    @ViewBuilder
    private var updateToolbarButton: some View {
        Button {
            updateChecker.toolbarTapped()
        } label: {
            // Spin a ProgressView while checking or downloading so the toolbar
            // visibly reflects that something is happening; otherwise show the
            // appropriate icon. SwiftUI re-renders this whenever `state`
            // changes because UpdateChecker is observed.
            switch updateChecker.state {
            case .checking, .downloading:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            default:
                Label("Updates", systemImage: updateChecker.toolbarSystemImage)
                    .foregroundStyle(updateChecker.toolbarTint ?? .primary)
            }
        }
        .help(updateChecker.toolbarTooltip)
    }

    @ViewBuilder
    private var mainPane: some View {
        if let project = selectedProject, store.orderedProjects.contains(project) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                    ProjectSidebar(
                            store: store,
                            processManager: processManager,
                            gitManager: gitManager,
                            project: project,
                            selectedTaskId: $selectedTaskId,
                            collapsedFolders: $collapsedFolders,
                            onEdit: { editingTask = $0 },
                            onDelete: { deleteTask($0) },
                            onDuplicate: { duplicateTask($0) },
                            onOpenClaudeHere: { openClaudeHere(for: $0) },
                            onShowBrowser: { showBrowser(for: $0) },
                            onSaveBundle: { folderPath, filePath in
                                saveBundle(folderPath: folderPath, to: filePath)
                            },
                            onExportBundle: { exportBundle(folderPath: $0) },
                            onDeleteFolder: { deleteFolder(path: $0) },
                            onDropReplace: { urls in handleDroppedURLs(urls, into: project) },
                            onPickImport: { pickAndImport(into: project) },
                            onAddTask: { addBlankTask(to: project) },
                            onQuickTap: { task in toggleQuickAction(task) },
                            onAddQuickAction: { addBlankTask(to: project, kind: "quick") },
                            onAddBrowser: { addBlankTask(to: project, kind: "browser") },
                            onAddGithub: { addBlankTask(to: project, kind: "github") },
                            onPickBookmark: { bookmark in addBookmarkAsTask(bookmark, to: project) },
                            onSaveBookmark: { task in saveTaskAsBookmark(task) },
                            onDeleteBookmark: { bookmark in store.removeBookmark(id: bookmark.id) },
                            onAddFolder: { parent in
                                addFolderTarget = AddFolderRequest(parent: parent)
                            },
                            onRenameFolder: { path in
                                renameFolderTarget = RenameFolderRequest(path: path)
                            },
                            onMoveTask: { task, folder in
                                store.moveTask(id: task.id, toFolder: folder)
                            },
                            onResumeClaude: { resumeClaudeTarget = $0 },
                            editMode: editMode,
                            isDirty: isProjectDirty(project),
                            onSaveSource: { saveProject(project) },
                            onReloadSource: { reloadSource(project: project) }
                        )
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } else {
            welcomePlaceholder
        }
    }

    private var currentProjectTasks: [DevTask] {
        guard let project = selectedProject else { return [] }
        return store.tasksUnder(project: project)
    }

    /// (running, total) per top-level project — fed to ProjectTabBar for the badge.
    private var runningCountsByProject: [String: (Int, Int)] {
        var result: [String: (Int, Int)] = [:]
        for project in store.orderedProjects {
            let tasks = store.tasksUnder(project: project)
            let running = tasks.filter { processManager.status($0.id).isRunning }.count
            result[project] = (running, tasks.count)
        }
        return result
    }

    /// ⌘1..⌘9 dispatch. If the active detail is a Claude-shortcut task, route
    /// the slot number to that task's Nth open session (1-indexed) so it
    /// behaves like the iTerm tab shortcuts users already have muscle memory
    /// for. Otherwise switch to the Nth project tab. No-op when the requested
    /// slot is out of range so a stray ⌘8 in a single-session project doesn't
    /// jump somewhere surprising.
    private func handleSlotShortcut(_ slot: Int) {
        let idx = slot - 1
        guard idx >= 0 else { return }

        if let taskId = selectedTaskId,
           let task = store.tasks.first(where: { $0.id == taskId }),
           task.isClaudeShortcut
        {
            let sessions = processManager.sessions(for: task.id)
            guard idx < sessions.count else { return }
            processManager.setActiveSession(taskId: task.id, sessionId: sessions[idx].id)
            return
        }

        let projects = store.orderedProjects
        guard idx < projects.count else { return }
        let target = projects[idx]
        if selectedProject != target {
            switchToProject(target)
        }
    }

    private func switchToProject(_ project: String) {
        if let prev = selectedProject, prev != project, let id = selectedTaskId {
            selectedTaskByProject[prev] = id
        }
        selectedProject = project
        let firstTask = store.tasksUnder(project: project).first?.id
        if let saved = selectedTaskByProject[project],
           store.tasks.contains(where: { $0.id == saved }) {
            selectedTaskId = saved
        } else {
            selectedTaskId = firstTask
        }
        lastValidTaskId = selectedTaskId
    }

    private func createEmptyProject() {
        let name = store.createEmptyProject()
        switchToProject(name)
    }

    private func showBrowser(for task: DevTask) {
        selectedTaskId = task.id
        if task.isBrowser || task.url != nil {
            activeTabs[task.id] = .browser
        }
    }

    // MARK: - tab management

    private func tabs(for task: DevTask) -> [DetailTab] {
        if task.isGithub { return [.github] }
        if task.isBrowser { return [.browser] }
        return task.url == nil ? [.terminal] : [.terminal, .browser]
    }

    private func activeTab(for task: DevTask) -> DetailTab {
        let available = tabs(for: task)
        if let recorded = activeTabs[task.id], available.contains(recorded) { return recorded }
        return available.first ?? .terminal
    }

    private func setActive(_ tab: DetailTab, for taskId: String) {
        activeTabs[taskId] = tab
    }

    // MARK: - Bundle save / export / replace

    private func bundle(forFolder folderPath: String) -> TaskBundle {
        let tasks = store.tasksUnder(path: folderPath)
        let prefix = folderPath + "/"
        let stripped = tasks.map { task -> DevTask in
            var t = task
            if let folder = t.folder {
                if folder == folderPath {
                    t.folder = nil
                } else if folder.hasPrefix(prefix) {
                    t.folder = String(folder.dropFirst(prefix.count))
                }
            }
            return t
        }
        return TaskBundle(name: folderPath, tasks: stripped)
    }

    private func writeBundle(_ bundle: TaskBundle, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        try data.write(to: url, options: .atomic)
    }

    private func saveBundle(folderPath: String, to filePath: String) {
        let url = URL(fileURLWithPath: filePath)
        let bundleData = bundle(forFolder: folderPath)
        do {
            try writeBundle(bundleData, to: url)
            importToast = "Saved to \(url.lastPathComponent)"
        } catch {
            importError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func saveProject(_ project: String) {
        guard let path = store.bundleSource(forFolder: project) else {
            saveProjectAs(project)
            return
        }
        saveBundle(folderPath: project, to: path)
    }

    private func saveProjectAs(_ project: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "heart.json"
        panel.canCreateDirectories = true
        panel.message = "Save '\(project)' as a Heart bundle"
        if let known = store.bundleSource(forFolder: project) {
            panel.directoryURL = URL(fileURLWithPath: known).deletingLastPathComponent()
            panel.nameFieldStringValue = (known as NSString).lastPathComponent
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleData = bundle(forFolder: project)
        do {
            try writeBundle(bundleData, to: url)
            store.setBundleSource(folder: project, path: url.path)
            importToast = "Saved to \(url.lastPathComponent)"
        } catch {
            importError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func exportBundle(folderPath: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "heart.json"
        panel.canCreateDirectories = true
        panel.message = "Export this folder as a Heart bundle"
        if let known = store.bundleSource(forFolder: folderPath) {
            panel.directoryURL = URL(fileURLWithPath: known).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleData = bundle(forFolder: folderPath)
        do {
            try writeBundle(bundleData, to: url)
            store.setBundleSource(folder: folderPath, path: url.path)
            importToast = "Exported to \(url.lastPathComponent)"
        } catch {
            importError = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func hasStartable(_ tasks: [DevTask]) -> Bool {
        tasks.contains { !processManager.status($0.id).isRunning }
    }
    private func hasStoppable(_ tasks: [DevTask]) -> Bool {
        tasks.contains { processManager.status($0.id).isRunning }
    }

    /// True when the project is linked to a heart.json but its on-disk content
    /// differs from the in-memory bundle. Used to surface the inline "Save"
    /// button in the SourceBar.
    private func isProjectDirty(_ project: String) -> Bool {
        guard let sourcePath = store.bundleSource(forFolder: project) else {
            return false
        }
        let currentBundle = bundle(forFolder: project)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let currentData = try? encoder.encode(currentBundle) else { return false }
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)) else {
            // File missing → treat as dirty so the user is prompted to re-save.
            return true
        }
        // Normalize the on-disk payload through the same encoder so whitespace /
        // key order don't trigger false-positive dirty states.
        let fileBundle: TaskBundle? = {
            if let parsed = try? JSONDecoder().decode(TaskBundle.self, from: fileData) {
                return parsed
            }
            if let arr = try? JSONDecoder().decode([DevTask].self, from: fileData) {
                return TaskBundle(name: nil, tasks: arr)
            }
            return nil
        }()
        guard let bundle = fileBundle,
              let normalizedFileData = try? encoder.encode(bundle) else {
            return true
        }
        return normalizedFileData != currentData
    }

    // MARK: - Task helpers

    private func duplicateTask(_ task: DevTask) {
        let copy = DevTask(
            id: UUID().uuidString,
            name: task.name + " (Copy)",
            command: task.command,
            cwd: task.cwd,
            port: task.port,
            url: task.url,
            autoStart: false,
            folder: task.folder,
            kind: task.kind
        )
        store.upsert(copy)
        selectedTaskId = copy.id
    }

    private func openClaudeHere(for task: DevTask) {
        let claudeTask = DevTask(
            id: UUID().uuidString,
            name: task.name + " • Claude",
            command: "claude",
            cwd: task.cwd,
            port: nil,
            url: nil,
            autoStart: false,
            folder: task.folder
        )
        store.upsert(claudeTask)
        selectedTaskId = claudeTask.id
        processManager.start(claudeTask)
    }

    private func addBlankTask(to project: String, kind: String? = nil) {
        // Browser-kind tasks never run a command — pre-fill placeholders so
        // EditTaskSheet's "Save" stays enabled without forcing the user to type
        // anything in the (hidden) Command / Working directory fields. GitHub
        // tasks leave command empty: the JSON shape for github omits it
        // entirely and EditTaskSheet's isValid doesn't require it.
        let placeholderCommand = (kind == "browser") ? ":" : ""
        let blank = DevTask(
            id: UUID().uuidString,
            name: "",
            command: placeholderCommand,
            cwd: NSHomeDirectory(),
            folder: project,
            kind: kind
        )
        editingTask = blank
    }

    /// Instantiate a saved bookmark as a browser task inside `project`. The
    /// resulting row mirrors the bookmark's name + icon and points at its URL.
    private func addBookmarkAsTask(_ bookmark: Bookmark, to project: String) {
        let task = DevTask(
            id: UUID().uuidString,
            name: bookmark.name,
            command: ":",
            cwd: NSHomeDirectory(),
            port: nil,
            url: bookmark.url,
            autoStart: false,
            folder: project,
            kind: "browser",
            icon: bookmark.icon
        )
        store.upsert(task)
        selectedTaskId = task.id
        activeTabs[task.id] = .browser
    }

    /// Save the task's current URL + name into the global bookmark library so
    /// it can be one-click added to any project from the "+ Browser" menu.
    private func saveTaskAsBookmark(_ task: DevTask) {
        guard let url = task.url, !url.isEmpty else { return }
        let name = task.name.trimmingCharacters(in: .whitespaces).isEmpty ? url : task.name
        store.addBookmark(name: name, url: url, icon: task.icon)
        importToast = "Saved '\(name)' to bookmarks"
    }

    /// Quick-action chip tapped — toggle process + select for the detail pane.
    /// Identical to a regular row tap but routes through here so we can keep the
    /// chip bar logic decoupled from the sidebar's normal selection handling.
    private func toggleQuickAction(_ task: DevTask) {
        if !store.tasks.contains(where: { $0.id == task.id }) {
            // Task may have just been edited and replaced — use the latest copy.
            return
        }
        if processManager.status(task.id).isRunning {
            processManager.stop(task)
            // Keep selection so the user can still see the buffer post-stop.
        } else {
            processManager.start(task)
            selectedTaskId = task.id
        }
    }

    private func deleteTask(_ task: DevTask) {
        if processManager.status(task.id).isRunning {
            processManager.stop(task)
        }
        if selectedTaskId == task.id {
            let project = selectedProject
            let projectTasks = project.map { store.tasksUnder(project: $0) } ?? []
            selectedTaskId = projectTasks.first(where: { $0.id != task.id })?.id
        }
        store.remove(id: task.id)
        browserManager.clear(taskId: task.id)
        gitManager.clear(taskId: task.id)
    }

    private func deleteFolder(path: String) {
        let toRemove = store.tasksUnder(path: path)
        for task in toRemove where processManager.status(task.id).isRunning {
            processManager.stop(task)
        }
        let removeIds = Set(toRemove.map(\.id))
        if let sel = selectedTaskId, removeIds.contains(sel) {
            let project = selectedProject
            let remaining = project
                .map { store.tasksUnder(project: $0).filter { !removeIds.contains($0.id) } }
                ?? []
            selectedTaskId = remaining.first?.id
        }
        store.removeFolder(path: path)
        for task in toRemove {
            browserManager.clear(taskId: task.id)
            gitManager.clear(taskId: task.id)
        }
    }

    private func performDeleteProject(_ name: String) {
        let toRemove = store.tasksUnder(project: name)
        for task in toRemove where processManager.status(task.id).isRunning {
            processManager.stop(task)
        }
        store.removeFolder(path: name)
        for task in toRemove {
            browserManager.clear(taskId: task.id)
            gitManager.clear(taskId: task.id)
        }
        selectedTaskByProject.removeValue(forKey: name)
        if selectedProject == name {
            selectedProject = store.orderedProjects.first
            if let p = selectedProject {
                selectedTaskId = selectedTaskByProject[p]
                    ?? store.tasksUnder(project: p).first?.id
            } else {
                selectedTaskId = nil
            }
        }
    }

    private func pickAndImport(into project: String?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = project.map { "Replace tasks of '\($0)' with contents of a JSON file" }
            ?? "Select a tasks.json file to import as a project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let project {
            queueReplace(url: url, project: project)
        } else {
            presentImport(for: url)
        }
    }

    // MARK: - Import pipeline

    private struct ResolvedBundle {
        var folder: String?
        var tasks: [DevTask]
        var sourcePath: String
        var suggestedFolderName: String
        var displayFileName: String
    }

    private enum ImportFailure: LocalizedError {
        case unreadable(file: String, underlying: Error)
        case unparseable(file: String, underlying: Error)
        case empty(file: String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let file, let error):
                return "Couldn't read \(file): \(error.localizedDescription)"
            case .unparseable(let file, let error):
                return "Couldn't parse \(file) as a Heart bundle.\n\n\(error.localizedDescription)"
            case .empty(let file):
                return "\(file) had no tasks with a `command` — nothing to import."
            }
        }
    }

    /// Drop callback. `into` = the project the drop landed on (sidebar drop), or
    /// nil if it landed on the tab bar / welcome screen (new-project drop).
    @discardableResult
    private func handleDroppedURLs(_ urls: [URL], into project: String?) -> Bool {
        guard let url = urls.first else {
            importError = "Drop didn't contain a file URL."
            return false
        }
        if let project {
            queueReplace(url: url, project: project)
        } else {
            presentImport(for: url)
        }
        return true
    }

    private func queueReplace(url: URL, project: String, computeDiff: Bool = false) {
        do {
            let resolved = try parseImport(at: url)
            let summary = computeDiff
                ? diffSummary(current: store.tasksUnder(project: project), incoming: resolved.tasks)
                : nil
            pendingReplace = PendingReplace(
                project: project,
                tasks: resolved.tasks,
                sourceURL: URL(fileURLWithPath: resolved.sourcePath),
                diffSummary: summary
            )
        } catch let failure as ImportFailure {
            importError = failure.errorDescription
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Trigger an explicit "Reload from disk" for a project that's already
    /// linked to a heart.json. Re-parses the file and queues the same confirm
    /// alert used for drag/drop replacement, with a diff summary so the user
    /// can see what changed before saying yes.
    private func reloadSource(project: String) {
        guard let path = store.bundleSource(forFolder: project) else { return }
        queueReplace(url: URL(fileURLWithPath: path), project: project, computeDiff: true)
    }

    /// Compare two task lists by id, return a human-readable one-liner. Used
    /// in the reload confirmation alert so the user knows whether to accept.
    private func diffSummary(current: [DevTask], incoming: [DevTask]) -> String {
        let currentById = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let incomingById = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let currentIds = Set(currentById.keys)
        let incomingIds = Set(incomingById.keys)
        let added = incomingIds.subtracting(currentIds).count
        let removed = currentIds.subtracting(incomingIds).count
        var modified = 0
        for (id, newTask) in incomingById {
            if let old = currentById[id], old != newTask { modified += 1 }
        }
        if added == 0 && removed == 0 && modified == 0 {
            return "No changes — disk matches memory."
        }
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if removed > 0 { parts.append("\(removed) removed") }
        if modified > 0 { parts.append("\(modified) modified") }
        return parts.joined(separator: " · ")
    }

    private func performReplace(_ req: PendingReplace) {
        // Stop any running tasks in the target project before replacing.
        for task in store.tasksUnder(project: req.project) where processManager.status(task.id).isRunning {
            processManager.stop(task)
        }
        store.replaceProject(req.project, with: req.tasks, source: req.sourceURL)
        processManager.scanForExternalServices(store.tasksUnder(project: req.project))
        importToast = "Replaced '\(req.project)' with \(req.tasks.count) task\(req.tasks.count == 1 ? "" : "s")"
        switchToProject(req.project)
    }

    private func presentImport(for url: URL) {
        do {
            let resolved = try parseImport(at: url)
            applyImport(resolved)
        } catch let failure as ImportFailure {
            importError = failure.errorDescription
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    private func parseImport(at url: URL) throws -> ResolvedBundle {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let displayName = url.lastPathComponent

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportFailure.unreadable(file: displayName, underlying: error)
        }

        let bundle = try decodeBundle(data: data, fileName: displayName)
        let stem = url.deletingPathExtension().lastPathComponent

        let normalized = bundle.tasks.map { task -> DevTask in
            var t = task
            let hasIcon = !(t.icon ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            // Only synthesize a name from the file stem if the task lacks BOTH
            // a name and an icon — an icon alone is enough identity.
            if t.name.trimmingCharacters(in: .whitespaces).isEmpty, !hasIcon {
                t.name = stem
            }
            return t
        }
        let cleaned = normalized.filter {
            !$0.command.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !cleaned.isEmpty else {
            throw ImportFailure.empty(file: displayName)
        }

        let trimmedFolder = bundle.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty()

        let suggested = stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        return ResolvedBundle(
            folder: trimmedFolder,
            tasks: cleaned,
            sourcePath: url.path,
            suggestedFolderName: suggested,
            displayFileName: displayName
        )
    }

    private func decodeBundle(data: Data, fileName: String) throws -> TaskBundle {
        if let parsed = try? JSONDecoder().decode(TaskBundle.self, from: data) {
            return parsed
        }
        if let array = try? JSONDecoder().decode([DevTask].self, from: data) {
            return TaskBundle(name: nil, tasks: array)
        }
        do {
            return try JSONDecoder().decode(TaskBundle.self, from: data)
        } catch {
            throw ImportFailure.unparseable(file: fileName, underlying: error)
        }
    }

    private func applyImport(_ resolved: ResolvedBundle) {
        guard let folder = resolved.folder else {
            pendingImport = PendingImport(
                tasks: resolved.tasks,
                suggestedName: resolved.suggestedFolderName,
                sourceFile: resolved.displayFileName,
                sourcePath: resolved.sourcePath
            )
            return
        }

        // Tab-bar drop always opens a NEW tab — if the bundle's `name` clashes
        // with an existing project, suffix it ("Maatrics" → "Maatrics (2)").
        // Replacing an existing project happens only when the user drops the
        // bundle directly onto that project's sidebar.
        let targetFolder = store.availableProjectName(base: folder)

        store.replaceProject(
            targetFolder,
            with: resolved.tasks,
            source: URL(fileURLWithPath: resolved.sourcePath)
        )

        processManager.scanForExternalServices(store.tasksUnder(path: targetFolder))
        importToast = (targetFolder == folder)
            ? "Imported \(resolved.tasks.count) task\(resolved.tasks.count == 1 ? "" : "s") into '\(targetFolder)'"
            : "Added new tab '\(targetFolder)' (\(resolved.tasks.count) task\(resolved.tasks.count == 1 ? "" : "s"))"
        switchToProject(targetFolder)
    }

    // MARK: - Detail pane

    private var resolvedTaskId: String? {
        if let id = selectedTaskId, store.tasks.contains(where: { $0.id == id }) {
            return id
        }
        return lastValidTaskId
    }

    @ViewBuilder
    private var detail: some View {
        if let id = resolvedTaskId, let task = store.tasks.first(where: { $0.id == id }) {
            if task.isClaudeShortcut {
                // Claude session containers keep their own per-session state in
                // ProcessManager — re-mount on task switch is fine here.
                ClaudeDetailView(task: task, processManager: processManager)
                    .id("claude-\(id)")
            } else if task.isGithub {
                GitHubView(task: task, gitManager: gitManager)
                    .id("github-\(id)")
            } else {
                // No `.id` here: OutputView swaps the terminalView in-place so
                // SwiftTerm's scroll position survives task switches.
                regularDetail(task: task, id: id)
            }
        } else {
            emptyProjectPlaceholder
        }
    }

    @ViewBuilder
    private var emptyProjectPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No task selected")
                .font(.title3.bold())
            if let project = selectedProject {
                if store.tasksUnder(project: project).isEmpty {
                    Text("'\(project)' has no tasks yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Drop a heart.json onto this project to replace it, click + Task in the sidebar to add one by hand, or read the format help to generate one with Claude.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        showFormatHelp = true
                    } label: {
                        Label("How do I write heart.json?", systemImage: "questionmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                } else {
                    Text("Pick a task from the sidebar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when there are no projects at all — pristine first-launch state.
    /// TaskStore guarantees `defaults` create "Project 1" so we should normally
    /// never hit this, but we keep it as a safety net.
    @ViewBuilder
    private var welcomePlaceholder: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.purple)
            Text("Welcome to Heart")
                .font(.title.bold())
            Text("Run your whole stack from one window — services, shortcuts, Claude sessions, quick actions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            HStack(spacing: 10) {
                Button {
                    createEmptyProject()
                } label: {
                    Label("Create empty project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    showFormatHelp = true
                } label: {
                    Label("Generate with Claude", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Text("Already have a heart.json? Drop it on the tab bar above.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func regularDetail(task: DevTask, id: String) -> some View {
        let availableTabs = tabs(for: task)
        let active = activeTab(for: task)
        VStack(spacing: 0) {
            detailTopBar(task: task, availableTabs: availableTabs, active: active)
            Divider()
            tabContent(task: task, availableTabs: availableTabs, active: active)
        }
    }

    @ViewBuilder
    private func detailTopBar(task: DevTask,
                              availableTabs: [DetailTab],
                              active: DetailTab) -> some View {
        let id = task.id
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if !task.isBrowser {
                    Circle()
                        .fill(processManager.status(id).color)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                Text(task.name.isEmpty ? (task.url ?? "Browser") : task.name)
                    .font(.headline)
                    .lineLimit(1)
                if !task.isBrowser {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(processManager.status(id).label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if let url = task.url, !url.isEmpty, !task.name.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if task.isBrowser, let urlString = task.url, !urlString.isEmpty {
                    Button {
                        TaskRow.openExternal(urlString)
                    } label: {
                        Label("Open externally", systemImage: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.purple)
                    .help("Open URL in the default external browser")
                }

                if let port = task.port {
                    Button {
                        processManager.killPort(port, for: id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.slash.fill")
                            Text(verbatim: "KILL PORT :\(port)")
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .help(Text(verbatim: "Kills any process listening on :\(port)"))
                }
                if active == .terminal {
                    Button {
                        processManager.repaint(id)
                    } label: {
                        Label("Repaint", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Force a full terminal redraw (use when characters look smeared / stacked vertically — Claude render glitch fix)")
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                    Button {
                        processManager.clearOutput(id)
                    } label: {
                        Label("Clear", systemImage: "eraser")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear terminal buffer")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                ForEach(availableTabs, id: \.self) { tab in
                    tabPill(tab: tab, isActive: tab == active, taskId: id)
                }
                Spacer()
                terminalPlusMenu(project: projectOf(task: task))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
    }

    /// "+" pill on the right of the detail-bar tab strip. Spawns a fresh
    /// terminal task in the current project from a saved cwd, or lets the
    /// user pick a brand-new one. Multiple taps on the same entry are
    /// intentional — each spawn creates a separate row + PTY.
    @ViewBuilder
    private func terminalPlusMenu(project: String?) -> some View {
        Menu {
            if store.terminalShortcuts.isEmpty {
                Text("No saved paths yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Divider()
            } else {
                ForEach(store.terminalShortcuts) { shortcut in
                    Button {
                        spawnTerminal(in: project, shortcut: shortcut)
                    } label: {
                        Label(shortcut.displayName, systemImage: "terminal")
                    }
                }
                Divider()
            }
            Button {
                pickAndAddTerminalPath(spawnAfter: project)
            } label: {
                Label("Browse for new path…", systemImage: "folder.badge.plus")
            }
            Button {
                showTerminalShortcuts = true
            } label: {
                Label("Manage paths…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.45),
                                style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open a new terminal at a saved path")
    }

    /// Find which top-level project a task belongs to so a freshly-spawned
    /// terminal lands next to its siblings, not at the root of some unrelated
    /// project (e.g. when the user has the same task selected across switches).
    private func projectOf(task: DevTask) -> String? {
        guard let folder = task.folder, !folder.isEmpty else {
            return selectedProject
        }
        return folder.split(separator: "/").first.map(String.init) ?? selectedProject
    }

    /// Create a brand-new shortcut-kind DevTask whose only job is to render a
    /// terminal at the given cwd. Routes through `store.upsert` so the new row
    /// shows up in the sidebar immediately, and selects it so the detail pane
    /// switches to its PTY.
    private func spawnTerminal(in project: String?, shortcut: TerminalShortcut) {
        let projectName = project ?? selectedProject ?? store.orderedProjects.first
        guard let projectName else { return }
        let expanded = (shortcut.path as NSString).expandingTildeInPath
        let label = shortcut.displayName
        let task = DevTask(
            id: "terminal-\(UUID().uuidString.prefix(8))",
            name: label,
            command: "exec zsh -l -i",
            cwd: expanded,
            port: nil,
            url: nil,
            autoStart: false,
            folder: projectName,
            kind: "shortcut",
            icon: "terminal"
        )
        store.upsert(task)
        selectedProject = projectName
        selectedTaskId = task.id
        activeTabs[task.id] = .terminal
        processManager.start(task)
    }

    /// File picker → save the chosen directory as a TerminalShortcut and
    /// (optionally) spawn a terminal at it right away. Saves only — repeated
    /// browsing for the same path silently de-dups via `addTerminalShortcut`.
    private func pickAndAddTerminalPath(spawnAfter project: String?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as terminal path"
        if panel.runModal() == .OK, let url = panel.url {
            let path = url.path
            let basename = url.lastPathComponent
            _ = store.addTerminalShortcut(name: basename, path: path)
            if let id = store.terminalShortcuts.first(where: { $0.path == path })?.id,
               let shortcut = store.terminalShortcuts.first(where: { $0.id == id }) {
                spawnTerminal(in: project, shortcut: shortcut)
            }
        }
    }

    @ViewBuilder
    private func tabPill(tab: DetailTab, isActive: Bool, taskId: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .font(.system(size: 10))
            Text(tab.label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2),
                        lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            setActive(tab, for: taskId)
        }
    }

    @ViewBuilder
    private func tabContent(task: DevTask,
                            availableTabs: [DetailTab],
                            active: DetailTab) -> some View {
        let id = task.id
        let status = processManager.status(id)
        ZStack {
            ZStack {
                OutputView(terminalView: processManager.terminalView(for: id))
                if status == .externalRunning {
                    externalRunningOverlay(task: task)
                } else if !status.isOwnedByHeart {
                    activateOverlay(task: task)
                }
            }
            .opacity(active == .terminal ? 1 : 0)
            .allowsHitTesting(active == .terminal)

            if availableTabs.contains(.browser), let url = task.url {
                // Model comes from BrowserManager so the WKWebView, its cookies,
                // history, scroll position, and granted permissions survive when
                // we switch to another task and back.
                BrowserView(url: url,
                            model: browserManager.model(for: id, initialURL: url))
                    .opacity(active == .browser ? 1 : 0)
                    .allowsHitTesting(active == .browser)
            }
        }
    }

    @ViewBuilder
    private func externalRunningOverlay(task: DevTask) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color(red: 0.4, green: 0.8, blue: 0.4))

            VStack(spacing: 4) {
                Text("Already running outside Heart")
                    .font(.title3.bold())
                if let port = task.port {
                    Text(verbatim: "Port :\(port) is bound by another process, so Heart can't show its output here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button {
                    if let port = task.port {
                        processManager.killPort(port, for: task.id)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        processManager.start(task)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Run in Heart").fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let port = task.port {
                    Button {
                        processManager.killPort(port, for: task.id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            processManager.statuses[task.id] = .stopped
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.slash")
                            Text(verbatim: "Free :\(port)")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func activateOverlay(task: DevTask) -> some View {
        let status = processManager.status(task.id)
        let isStarting = status == .starting
        let crashedCode: Int32? = {
            if case let .crashed(code) = status { return code }
            return nil
        }()
        VStack(spacing: 14) {
            Image(systemName: isStarting ? "hourglass" : "bolt.circle.fill")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isStarting ? Color.yellow : Color.accentColor)

            VStack(spacing: 4) {
                if let code = crashedCode {
                    Text("Crashed (exit \(code))")
                        .font(.title3.bold())
                        .foregroundStyle(.red)
                } else if isStarting {
                    Text("Starting…")
                        .font(.title3.bold())
                } else {
                    Text("Terminal idle")
                        .font(.title3.bold())
                }
                Text(verbatim: task.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                processManager.start(task)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text(crashedCode != nil ? "Restart" : "Activate")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isStarting)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

// MARK: - EditTaskSheet

struct EditTaskSheet: View {
    let task: DevTask
    let onCancel: () -> Void
    let onSave: (DevTask) -> Void

    @State private var name: String
    @State private var command: String
    @State private var cwd: String
    @State private var portText: String
    @State private var url: String
    @State private var folder: String
    @State private var autoStart: Bool
    @State private var taskKind: TaskKind
    @State private var icon: String?
    @State private var showIconPicker: Bool = false

    enum TaskKind: String, CaseIterable, Identifiable {
        case service, shortcut, claude, quick, browser, github
        var id: String { rawValue }
        var label: String {
            switch self {
            case .service:  return "Service"
            case .shortcut: return "Shortcut"
            case .claude:   return "Claude"
            case .quick:    return "Quick"
            case .browser:  return "Browser"
            case .github:   return "GitHub"
            }
        }
        var iconName: String {
            switch self {
            case .service:  return "server.rack"
            case .shortcut: return "arrow.right.circle.fill"
            case .claude:   return "sparkles"
            case .quick:    return "bolt.fill"
            case .browser:  return "globe"
            case .github:   return "chevron.left.forwardslash.chevron.right"
            }
        }
        var detail: String {
            switch self {
            case .service:
                return "Long-running process. Manual start/stop, status indicator, runs in its own terminal."
            case .shortcut:
                return "Generic launcher (ssh, kubectl, scp, custom REPLs). Sits in the sidebar with no play/stop buttons — clicking the row runs the command and shows its terminal. No port / URL config."
            case .claude:
                return "Pinned at the top of the sidebar. Each click opens a fresh terminal session — good for keeping multiple Claude chats in the same dir."
            case .quick:
                return "Surfaced as a chip above the sidebar. One click runs the command and shows its output; click again to stop. No port / URL config."
            case .browser:
                return "URL-only bookmark. Clicking the row opens the page in Heart's built-in browser; an arrow icon next to it opens the URL in your default external browser."
            case .github:
                return "Git repository panel — GitHub Desktop style. Sidebar row shows branch + dirty count; clicking opens changed files (left) + diff (right) + commit bar (bottom) + push/pull (top). Only `cwd` is required."
            }
        }
    }

    init(task: DevTask, onCancel: @escaping () -> Void, onSave: @escaping (DevTask) -> Void) {
        self.task = task
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: task.name)
        _command = State(initialValue: task.command)
        _cwd = State(initialValue: task.cwd)
        _portText = State(initialValue: task.port.map { String($0) } ?? "")
        _url = State(initialValue: task.url ?? "")
        _folder = State(initialValue: task.folder ?? "")
        _autoStart = State(initialValue: task.autoStart)
        let initialKind: TaskKind = task.isClaudeShortcut ? .claude
            : (task.isQuickAction ? .quick
               : (task.isShortcut ? .shortcut
                  : (task.isBrowser ? .browser
                     : (task.isGithub ? .github : .service))))
        _taskKind = State(initialValue: initialKind)
        _icon = State(initialValue: task.icon)
    }

    private var isNewTask: Bool {
        task.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        task.command.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // Type lives at the top now. The form below adapts to the
                    // chosen kind (Browser hides Command, GitHub shows only a
                    // repo path, …) so picking late used to wipe the user's
                    // typed Command field — putting Type first removes that
                    // surprise.
                    section(title: "Type", icon: "switch.2") {
                        typeCardGrid
                    }

                    section(title: "Essentials", icon: "doc.text") {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(spacing: 6) {
                                Text("ICON")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(0.6)
                                iconPickerButton
                            }
                            VStack(alignment: .leading, spacing: 16) {
                                field(label: "Name",
                                      hint: "Shown in the sidebar. Optional when an icon is selected.") {
                                    styledTextField(placeholder: "My dev server", text: $name)
                                }
                            }
                        }
                        field(label: "Project / Folder",
                              hint: "Top-level segment becomes the tab name. Use \"/\" for sub-folders, e.g. Backend/Workers.") {
                            styledTextField(placeholder: "Project 1", text: $folder)
                        }
                        if taskKind == .browser {
                            field(label: "URL",
                                  hint: "Required. Loaded in Heart's built-in browser when this row is selected.") {
                                styledTextField(placeholder: "https://example.com",
                                                text: $url,
                                                monospaced: true)
                            }
                        } else if taskKind == .github {
                            field(label: "Repository path",
                                  hint: "Required. Path to the local git working directory. Tilde (~) expands to your home folder.") {
                                directoryRow
                            }
                        } else {
                            field(label: "Command",
                                  hint: "Runs in zsh -l -i inside a PTY.") {
                                styledTextField(placeholder: "npm run dev",
                                                text: $command,
                                                monospaced: true)
                            }
                            field(label: "Working directory",
                                  hint: "Where the command runs. Tilde (~) expands to your home folder.") {
                                directoryRow
                            }
                        }
                    }

                    if taskKind == .service {
                        section(title: "Network", icon: "network") {
                            field(label: "Port",
                                  hint: "Optional. Enables the KILL PORT button and a readiness check (status stays Starting until the port binds).") {
                                styledTextField(placeholder: "3000",
                                                text: $portText,
                                                monospaced: true)
                                    .onChange(of: portText) { new in
                                        let filtered = new.filter(\.isNumber)
                                        if filtered != new { portText = filtered }
                                    }
                            }
                            field(label: "URL",
                                  hint: "Optional. Adds a Browser tab to the detail pane.") {
                                styledTextField(placeholder: "http://localhost:3000",
                                                text: $url,
                                                monospaced: true)
                            }
                            Toggle(isOn: $autoStart) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Auto-start on launch")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("Reserved — the UI flag is saved but not yet acted upon.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }

            Divider()

            footer
        }
        .frame(width: 600, height: 720)
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// 2×3 button grid for selecting the task kind. Each card surfaces the
    /// icon, label, and the first sentence of the kind's detail string so the
    /// user can pick at a glance without having to commit and then read.
    /// Reuses `TaskKind.iconName` and `TaskKind.detail`.
    @ViewBuilder
    private var typeCardGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(TaskKind.allCases) { kind in
                typeCard(kind: kind)
            }
        }
    }

    @ViewBuilder
    private func typeCard(kind: TaskKind) -> some View {
        let isSelected = (taskKind == kind)
        Button {
            taskKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: kind.iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(kind.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.primary : .secondary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(Self.firstSentence(of: kind.detail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.14)
                          : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected
                                  ? Color.accentColor.opacity(0.65)
                                  : Color.secondary.opacity(0.18),
                                  lineWidth: isSelected ? 1.2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.detail)
    }

    /// Trim a multi-sentence detail string down to the first sentence so the
    /// type card stays compact. Falls back to the whole string when there's
    /// no period to split on.
    private static func firstSentence(of s: String) -> String {
        if let dot = s.firstIndex(of: ".") {
            return String(s[...dot])
        }
        return s
    }

    // MARK: - sections

    @ViewBuilder
    private var iconPickerButton: some View {
        Button {
            showIconPicker = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.accentColor.opacity(0.12))
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 0.8, dash: icon == nil ? [3, 2] : []))
                Image(systemName: icon ?? "square.grid.2x2")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .help(icon ?? "Choose icon")
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(
                current: icon,
                onCancel: { showIconPicker = false },
                onPick: { picked in
                    icon = picked
                    showIconPicker = false
                }
            )
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String,
                                        icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 0.5)
            }
            VStack(alignment: .leading, spacing: 16) { content() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: isNewTask ? "plus" : "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(isNewTask ? "New task" : "Edit task")
                    .font(.system(size: 16, weight: .semibold))
                if !isNewTask {
                    Text(verbatim: "id: \(task.id)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Fill in the essentials and click Save.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }

    private var directoryRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                if cwd.isEmpty {
                    Text("Choose a directory…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(displayPath(cwd))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(cwd)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )

            Button {
                pickDirectory()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                    Text("Browse")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(isNewTask ? "Add task" : "Save changes") { commit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    // MARK: - helpers

    @ViewBuilder
    private func field<Content: View>(label: String,
                                      hint: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func styledTextField(placeholder: String,
                                 text: Binding<String>,
                                 monospaced: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(NSColor.textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var isValid: Bool {
        // Either a name or an icon is enough to identify the task in the UI —
        // we only require one of the two so users can ship icon-only chips.
        let hasIdentity = !name.trimmingCharacters(in: .whitespaces).isEmpty
            || !(icon ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let hasCwd = !cwd.trimmingCharacters(in: .whitespaces).isEmpty
        switch taskKind {
        case .browser:
            // Browser bookmarks require only identity + a URL.
            return hasIdentity && !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .github:
            // GitHub repos require only identity + a working directory.
            return hasIdentity && hasCwd
        default:
            let hasCommand = !command.trimmingCharacters(in: .whitespaces).isEmpty
            return hasIdentity && hasCommand && hasCwd
        }
    }

    private func commit() {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: Int? = Int(portText.trimmingCharacters(in: .whitespaces))
        let kindString: String? = {
            switch taskKind {
            case .service:  return nil
            case .shortcut: return "shortcut"
            case .claude:   return "claude"
            case .quick:    return "quick"
            case .browser:  return "browser"
            case .github:   return "github"
            }
        }()
        // Port / URL only apply to long-running services or browser bookmarks —
        // strip them on the other kinds so a user who toggled the type doesn't
        // leave dead config behind in the JSON.
        let resolvedPort: Int? = (taskKind == .service) ? port : nil
        let resolvedURL: String? = {
            guard !trimmedURL.isEmpty else { return nil }
            return (taskKind == .service || taskKind == .browser) ? trimmedURL : nil
        }()
        // Browser bookmarks store a `:` placeholder so the required-field
        // contract is met; github stores empty command (its JSON shape omits
        // the field entirely — DevTask decoder is fine with a blank default).
        let resolvedCommand: String = {
            switch taskKind {
            case .browser: return ":"
            case .github:  return ""
            default:       return command.trimmingCharacters(in: .whitespaces)
            }
        }()
        let resolvedCwd: String = (taskKind == .browser)
            ? (cwd.trimmingCharacters(in: .whitespaces).isEmpty
               ? NSHomeDirectory()
               : cwd.trimmingCharacters(in: .whitespaces))
            : cwd.trimmingCharacters(in: .whitespaces)
        let updated = DevTask(
            id: task.id,
            name: name.trimmingCharacters(in: .whitespaces),
            command: resolvedCommand,
            cwd: resolvedCwd,
            port: resolvedPort,
            url: resolvedURL,
            autoStart: autoStart,
            folder: trimmedFolder.isEmpty ? nil : trimmedFolder,
            kind: kindString,
            icon: icon,
            order: task.order
        )
        onSave(updated)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let initial = cwd.isEmpty
            ? NSHomeDirectory()
            : (cwd as NSString).expandingTildeInPath
        panel.directoryURL = URL(fileURLWithPath: initial)
        if panel.runModal() == .OK, let url = panel.url {
            cwd = url.path
        }
    }
}

// MARK: - DropZoneView

struct DropZoneView: View {
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(isTargeted
                 ? "Drop to replace this project"
                 : "Drop or click to replace this project")
                .font(.system(size: 10))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
        )
        .contentShape(Rectangle())
    }
}

// MARK: - PendingImport / PendingReplace / RenameRequest

struct PendingImport: Identifiable {
    let id = UUID()
    let tasks: [DevTask]
    let suggestedName: String
    let sourceFile: String
    let sourcePath: String?
}

struct PendingReplace: Identifiable {
    let id = UUID()
    let project: String
    let tasks: [DevTask]
    let sourceURL: URL
    /// One-line summary like "2 added · 1 removed · 3 modified", or
    /// "No changes" when disk matches memory. Surfaced in the confirm alert
    /// so the user can decide whether the reload is worth it. nil = caller
    /// didn't compute it (e.g. fresh import, not a reload).
    var diffSummary: String?
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let currentName: String
}

struct AddFolderRequest: Identifiable {
    let id = UUID()
    /// Parent folder absolute path. Empty string = project root (caller must
    /// prepend the project name before calling `store.addFolder`).
    let parent: String
}

struct RenameFolderRequest: Identifiable {
    let id = UUID()
    let path: String
}

// MARK: - Prompts

struct ImportFolderPrompt: View {
    let pending: PendingImport
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var folderName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                Text("Import as project")
                    .font(.title3.bold())
            }

            Text("Found \(pending.tasks.count) task(s) in \(pending.sourceFile). Name the project:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Project name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirm() }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { folderName = pending.suggestedName }
    }

    private func confirm() {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}

struct AddFolderPrompt: View {
    let parent: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                Text("New folder")
                    .font(.title3.bold())
            }

            Text(parent.isEmpty
                 ? "Folder will be created at the project root."
                 : "Folder will be created inside '\(parent)'.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirm() }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func confirm() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}

struct RenameFolderPrompt: View {
    let currentPath: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var newName: String = ""

    private var currentName: String {
        currentPath.split(separator: "/").last.map(String.init) ?? currentPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                Text("Rename folder")
                    .font(.title3.bold())
            }

            Text("Renaming '\(currentPath)'. Tasks inside this folder (and any nested folders) keep their data — only the folder path changes.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Folder name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirm() }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { newName = currentName }
    }

    private var isValid: Bool {
        let t = newName.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t != currentName
    }

    private func confirm() {
        let t = newName.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onConfirm(t)
    }
}

struct RenameProjectPrompt: View {
    let currentName: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                Text("Rename project")
                    .font(.title3.bold())
            }

            Text("Pick a new name for '\(currentName)'. Tasks and source link are preserved.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Project name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirm() }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { newName = currentName }
    }

    private var isValid: Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != currentName
    }

    private func confirm() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}

// MARK: -

private extension String {
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
