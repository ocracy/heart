import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DetailTab: String, CaseIterable, Hashable {
    case terminal
    case browser

    var label: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        }
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .browser: return "globe"
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var processManager: ProcessManager

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
    @State private var sidebarHidden: Bool = false
    @State private var activeTabs: [String: DetailTab] = [:]
    /// Pending project to delete (with confirm dialog).
    @State private var deleteProjectTarget: String?
    @State private var showFormatHelp = false

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
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showFormatHelp) {
            JSONFormatHelp(onClose: { showFormatHelp = false })
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
            Text("Replace tasks of '\(req.project)' with contents of \(req.sourceURL.lastPathComponent)?\nThis will overwrite all tasks in this project.")
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
        ToolbarItemGroup {
            Button { toggleSidebar() } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help("Toggle sidebar (⌃⌘S)")

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

            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Edit tasks")
        }
    }

    @ViewBuilder
    private var mainPane: some View {
        if let project = selectedProject, store.orderedProjects.contains(project) {
            Group {
                if sidebarHidden {
                    detail
                } else {
                    NavigationSplitView(columnVisibility: .constant(.all)) {
                        ProjectSidebar(
                            store: store,
                            processManager: processManager,
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
                            onAddTask: { addBlankTask(to: project) }
                        )
                    } detail: {
                        detail
                    }
                    .navigationSplitViewStyle(.balanced)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
                }
            }
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

    private func toggleSidebar() { sidebarHidden.toggle() }

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
        if task.url != nil {
            activeTabs[task.id] = .browser
        }
    }

    // MARK: - tab management

    private func tabs(for task: DevTask) -> [DetailTab] {
        task.url == nil ? [.terminal] : [.terminal, .browser]
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

    private func addBlankTask(to project: String) {
        let blank = DevTask(
            id: UUID().uuidString,
            name: "",
            command: "",
            cwd: NSHomeDirectory(),
            folder: project
        )
        editingTask = blank
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
    }

    private func performDeleteProject(_ name: String) {
        let toRemove = store.tasksUnder(project: name)
        for task in toRemove where processManager.status(task.id).isRunning {
            processManager.stop(task)
        }
        store.removeFolder(path: name)
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

    private func queueReplace(url: URL, project: String) {
        do {
            let resolved = try parseImport(at: url)
            pendingReplace = PendingReplace(
                project: project,
                tasks: resolved.tasks,
                sourceURL: URL(fileURLWithPath: resolved.sourcePath)
            )
        } catch let failure as ImportFailure {
            importError = failure.errorDescription
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
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
            if t.name.trimmingCharacters(in: .whitespaces).isEmpty { t.name = stem }
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

        // Refresh-on-collision: same folder name = user updated their config and
        // re-dropped. Replace the contents instead of suffixing duplicates.
        let existing = store.tasksUnder(path: folder)
        if !existing.isEmpty {
            for task in existing where processManager.status(task.id).isRunning {
                processManager.stop(task)
            }
            store.removeFolder(path: folder)
        }
        store.append(resolved.tasks, folder: folder)
        store.setBundleSource(folder: folder, path: resolved.sourcePath)

        processManager.scanForExternalServices(store.tasksUnder(path: folder))
        importToast = "Imported \(resolved.tasks.count) task\(resolved.tasks.count == 1 ? "" : "s") into '\(folder)'"
        switchToProject(folder)
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
                ClaudeDetailView(task: task, processManager: processManager)
                    .id("claude-\(id)")
            } else {
                regularDetail(task: task, id: id)
                    .id("regular-\(id)")
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
                    Text("Drop a heart.json onto this project to replace it, or add tasks via Settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
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
            Text("Run your whole stack from one window.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                createEmptyProject()
            } label: {
                Label("Create your first project", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
                Circle()
                    .fill(processManager.status(id).color)
                    .frame(width: 8, height: 8)
                Text(task.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(processManager.status(id).label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

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
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .background(.ultraThinMaterial)
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
                BrowserView(url: url)
                    .id("browser-\(id)")
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
    @State private var isClaudeShortcut: Bool

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
        _isClaudeShortcut = State(initialValue: task.isClaudeShortcut)
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
                    section(title: "Essentials", icon: "doc.text") {
                        field(label: "Name",
                              hint: "Shown in the sidebar.") {
                            styledTextField(placeholder: "My dev server", text: $name)
                        }
                        field(label: "Project / Folder",
                              hint: "Top-level segment becomes the tab name. Use \"/\" for sub-folders, e.g. Backend/Workers.") {
                            styledTextField(placeholder: "Project 1", text: $folder)
                        }
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
                    }

                    section(title: "Behavior", icon: "switch.2") {
                        Toggle(isOn: $isClaudeShortcut) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Color.purple)
                                    Text("Claude shortcut")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                Text("Pins the task at the top of the sidebar and opens a fresh terminal session each time it's clicked (good for keeping multiple `claude` chats in the same dir).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

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
                .padding(.horizontal, 26)
                .padding(.vertical, 24)
            }

            Divider()

            footer
        }
        .frame(width: 600, height: 700)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - sections

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
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !command.trimmingCharacters(in: .whitespaces).isEmpty &&
        !cwd.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func commit() {
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: Int? = Int(portText.trimmingCharacters(in: .whitespaces))
        let updated = DevTask(
            id: task.id,
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            cwd: cwd.trimmingCharacters(in: .whitespaces),
            port: port,
            url: trimmedURL.isEmpty ? nil : trimmedURL,
            autoStart: autoStart,
            folder: trimmedFolder.isEmpty ? nil : trimmedFolder,
            kind: isClaudeShortcut ? "claude" : nil
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
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let currentName: String
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
