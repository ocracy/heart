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

    @State private var selectedTaskId: String?
    @State private var showSettings = false
    @State private var collapsedFolders: Set<String> = []
    @State private var isDropTargeted = false
    @State private var pendingImport: PendingImport?
    @State private var editingTask: DevTask?
    @State private var importError: String?
    @State private var importToast: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var activeTabs: [String: DetailTab] = [:]

    /// macOS NavigationSplitView occasionally tries to auto-collapse the sidebar
    /// in response to selection changes / window resizes / animations. We don't
    /// want that — the sidebar should stay visible until the user explicitly
    /// hits the toolbar button (or ⌃⌘S). Drop system-driven writes, accept
    /// reads from `columnVisibility` so our own toggle still animates.
    private var stableColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { columnVisibility },
            set: { _ in /* ignore */ }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: stableColumnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    toggleSidebar()
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help("Toggle sidebar (⌃⌘S)")

                Button {
                    processManager.startAll(store.tasks)
                } label: {
                    Label("Start All", systemImage: "play.circle.fill")
                }
                .help("Start every task")
                .disabled(!hasStartable(store.tasks))

                Button {
                    processManager.stopAll(store.tasks)
                } label: {
                    Label("Stop All", systemImage: "stop.circle.fill")
                }
                .help("Stop every task")
                .disabled(!hasStoppable(store.tasks))

                Spacer()

                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .help("Edit tasks")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .sheet(item: $pendingImport) { pending in
            ImportFolderPrompt(
                pending: pending,
                onCancel: { pendingImport = nil },
                onConfirm: { folder in
                    store.append(pending.tasks, folder: folder)
                    processManager.scanForExternalServices(store.tasksUnder(path: folder))
                    importToast = "Imported \(pending.tasks.count) task\(pending.tasks.count == 1 ? "" : "s") into '\(folder)'"
                    pendingImport = nil
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
        .onAppear {
            if selectedTaskId == nil {
                selectedTaskId = store.tasks.first?.id
            }
            // First-pass scan: anything with a port already bound by some other
            // process (redis on :6379, postgres, a leftover dev server) shows up
            // as running so the dot is green from the start.
            processManager.scanForExternalServices(store.tasks)
        }
        .alert("Import failed",
               isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
               ),
               actions: {
                   Button("OK") { importError = nil }
               },
               message: {
                   Text(importError ?? "")
               })
        .overlay(alignment: .top) {
            if let toast = importToast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.green.opacity(0.85))
                    )
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: importToast)
        .onChange(of: importToast) { newValue in
            // Auto-dismiss after 3 s. Capture the current value so a second toast
            // arriving in the meantime doesn't get erased early.
            guard let value = newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if importToast == value { importToast = nil }
            }
        }
    }

    private func toggleSidebar() {
        switch columnVisibility {
        case .detailOnly:
            columnVisibility = .all
        default:
            columnVisibility = .detailOnly
        }
    }

    private func showBrowser(for task: DevTask) {
        selectedTaskId = task.id
        if task.url != nil {
            activeTabs[task.id] = .browser
        }
    }

    // MARK: - tab management

    /// Tabs available for a regular (non-Claude) task. Fixed by task config — Browser only
    /// shows up when a URL is set. Tabs are not closeable; switching is the only interaction.
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedTaskId) {
                let root = store.buildTree()
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
                .onTapGesture {
                    pickAndImport()
                }
        }
        // Use the modern Transferable-based API — earlier `onDrop` +
        // `provider.loadItem` was racy: the async callback occasionally fired
        // after SwiftUI invalidated the view, dropping the file silently.
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        // Big in-your-face overlay while a file is being dragged — the dashed
        // footer hint is too easy to miss when the task list scrolls past it.
        .overlay {
            if isDropTargeted {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    VStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 36, weight: .light))
                        Text("Drop heart.json to import")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Existing folder of the same name is refreshed.")
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
    }

    /// Picks the right row style for a task — Claude shortcuts get a sparkles row that
    /// hides start/stop buttons (multi-session, opened by tapping); everything else uses TaskRow.
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
                    onShowBrowser: { showBrowser(for: task) })
                .tag(task.id)
                .contextMenu { rowMenu(for: task) }
        }
    }

    @ViewBuilder
    private func claudeRowMenu(for task: DevTask) -> some View {
        Button {
            editingTask = task
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button {
            duplicateTask(task)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Divider()
        Button(role: .destructive) {
            deleteTask(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func pickAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Select a tasks.json file to import as a folder"
        if panel.runModal() == .OK, let url = panel.url {
            presentImport(for: url)
        }
    }

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
            .onTapGesture {
                if isCollapsed {
                    collapsedFolders.remove(node.path)
                } else {
                    collapsedFolders.insert(node.path)
                }
            }

            HStack(spacing: 6) {
                folderIconButton(systemName: "play.fill", tint: .green, help: "Start all tasks in folder", enabled: hasStartable(allTasks)) {
                    processManager.startAll(allTasks)
                }
                folderIconButton(systemName: "stop.fill", tint: .red, help: "Stop all tasks in folder", enabled: hasStoppable(allTasks)) {
                    processManager.stopAll(allTasks)
                }
                folderIconButton(systemName: "arrow.clockwise", tint: .secondary, help: "Restart all tasks in folder", enabled: !allTasks.isEmpty) {
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
            }
            .disabled(!hasStartable(allTasks))
            Button { processManager.stopAll(allTasks) } label: {
                Label("Stop all", systemImage: "stop.fill")
            }
            .disabled(!hasStoppable(allTasks))
            Button { for task in allTasks { processManager.restart(task) } } label: {
                Label("Restart all", systemImage: "arrow.clockwise")
            }
            .disabled(allTasks.isEmpty)
            Divider()
            if let sourcePath = store.bundleSource(forFolder: node.path) {
                Button {
                    saveBundle(folderPath: node.path, to: sourcePath)
                } label: {
                    Label("Save to \((sourcePath as NSString).lastPathComponent)",
                          systemImage: "square.and.arrow.down")
                }
            }
            Button {
                exportBundle(folderPath: node.path)
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .disabled(allTasks.isEmpty)
            Divider()
            Button(role: .destructive) {
                deleteFolder(path: node.path)
            } label: {
                Label("Delete folder (\(totalCount) tasks)", systemImage: "trash")
            }
        }
    }

    /// Build a TaskBundle from a folder by stripping the folder prefix off each
    /// task's `folder` value — so a task imported into "polymarket/Frontend"
    /// round-trips back to `folder: "Frontend"` (relative to the bundle's name).
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
        } catch {
            importError = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func exportBundle(folderPath: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "heart.json"
        panel.canCreateDirectories = true
        panel.message = "Export this folder as a Heart bundle"
        // Default to the previously-known path's directory if we have one.
        if let known = store.bundleSource(forFolder: folderPath) {
            panel.directoryURL = URL(fileURLWithPath: known).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleData = bundle(forFolder: folderPath)
        do {
            try writeBundle(bundleData, to: url)
            // Remember the new destination so the next "Save" lands here.
            store.setBundleSource(folder: folderPath, path: url.path)
        } catch {
            importError = "Couldn't export: \(error.localizedDescription)"
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

    /// True when at least one task is not currently alive — i.e. clicking "start" would do something.
    /// Treats `.starting` as already-alive so we don't re-fire start on a task that's already coming up.
    private func hasStartable(_ tasks: [DevTask]) -> Bool {
        tasks.contains { !processManager.status($0.id).isRunning }
    }

    /// True when at least one task is currently alive (running / starting / stopping) and could be stopped.
    private func hasStoppable(_ tasks: [DevTask]) -> Bool {
        tasks.contains { processManager.status($0.id).isRunning }
    }

    @ViewBuilder
    private func rowMenu(for task: DevTask) -> some View {
        let isRunning = processManager.status(task.id).isRunning
        Button {
            processManager.toggle(task)
        } label: {
            Label(isRunning ? "Stop" : "Start",
                  systemImage: isRunning ? "stop.fill" : "play.fill")
        }
        Button {
            processManager.restart(task)
        } label: {
            Label("Restart", systemImage: "arrow.clockwise")
        }
        Divider()
        Button {
            editingTask = task
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button {
            duplicateTask(task)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button {
            openClaudeHere(for: task)
        } label: {
            Label("Open Claude Here", systemImage: "sparkles")
        }
        Divider()
        Button(role: .destructive) {
            deleteTask(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

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

    private func deleteTask(_ task: DevTask) {
        if processManager.status(task.id).isRunning {
            processManager.stop(task)
        }
        if selectedTaskId == task.id {
            selectedTaskId = store.tasks.first(where: { $0.id != task.id })?.id
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
            selectedTaskId = store.tasks.first(where: { !removeIds.contains($0.id) })?.id
        }
        store.removeFolder(path: path)
    }


    // MARK: - Import pipeline

    /// Outcome of parsing a heart.json off disk — either a fully-resolved bundle
    /// (auto-import under `folder`) or one that needs the user to name a folder.
    private struct ResolvedBundle {
        var folder: String?            // nil → ask the user for a folder name
        var tasks: [DevTask]
        var sourcePath: String         // remembered for "Save" later
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

    /// Drop callback. Runs synchronously on the main actor — see dropDestination.
    private func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard let url = urls.first else {
            importError = "Drop didn't contain a file URL."
            return false
        }
        presentImport(for: url)
        return true
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

    /// Read + decode + normalize, no store mutations. Throws `ImportFailure`.
    private func parseImport(at url: URL) throws -> ResolvedBundle {
        // Sandboxed Finder URLs need scoped access before reading.
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

    /// Try the bundle shape first, fall back to a bare DevTask array. Both shapes
    /// failing → re-decode as a bundle to surface the most useful error message.
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

    /// Mutate the store + select / scan / report. Pure side effects; safe to call
    /// only after `parseImport` succeeded.
    private func applyImport(_ resolved: ResolvedBundle) {
        guard let folder = resolved.folder else {
            // Bundle had no top-level name → ask user where to put the tasks.
            pendingImport = PendingImport(
                tasks: resolved.tasks,
                suggestedName: resolved.suggestedFolderName,
                sourceFile: resolved.displayFileName
            )
            return
        }

        // Refresh-on-collision: same folder name = user updated their config and
        // re-dropped. Replace the contents instead of suffixing duplicates.
        let existing = store.tasksUnder(path: folder)
        let selectionWasInsideFolder = selectedTaskId.map {
            Set(existing.map(\.id)).contains($0)
        } ?? false

        if !existing.isEmpty {
            for task in existing where processManager.status(task.id).isRunning {
                processManager.stop(task)
            }
            store.removeFolder(path: folder)
        }
        store.append(resolved.tasks, folder: folder)
        store.setBundleSource(folder: folder, path: resolved.sourcePath)

        // Auto-select inside the folder if the user was on the welcome screen
        // or had a now-deleted task selected.
        if selectedTaskId == nil || selectionWasInsideFolder {
            selectedTaskId = store.tasksUnder(path: folder).first?.id
                ?? store.tasks.first?.id
        }

        processManager.scanForExternalServices(store.tasksUnder(path: folder))
        importToast = "Imported \(resolved.tasks.count) task\(resolved.tasks.count == 1 ? "" : "s") into '\(folder)'"
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedTaskId, let task = store.tasks.first(where: { $0.id == id }) {
            if task.isClaudeShortcut {
                ClaudeDetailView(task: task, processManager: processManager)
                    .id("claude-\(id)")
            } else {
                regularDetail(task: task, id: id)
            }
        } else {
            emptyStatePlaceholder
        }
    }

    /// Shown when nothing is selected — doubles as a quick-start guide for new users
    /// (drag-drop a heart.json, or generate one with the Claude Code skill).
    @ViewBuilder
    private var emptyStatePlaceholder: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.purple)
            Text("Welcome to Heart")
                .font(.title.bold())
            Text("Run your whole stack from one window.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                quickStartRow(number: 1,
                              title: "Open your project",
                              detail: "cd into the project and run `claude`.")
                quickStartRow(number: 2,
                              title: "Generate heart.json",
                              detail: "Paste this prompt into Claude:",
                              code: "Read https://raw.githubusercontent.com/ocracy/heart/refs/heads/main/heart-json-generator.md and generate heart.json for this project following that format.")
                quickStartRow(number: 3,
                              title: "Drop it here",
                              detail: "Drag the generated heart.json onto Heart's sidebar.")
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .frame(maxWidth: 560)

            Link(destination: URL(string: "https://github.com/ocracy/heart")!) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Documentation")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // Highlight tint while a file is being dragged over the welcome panel.
            RoundedRectangle(cornerRadius: 0)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .top) {
            if isDropTargeted {
                Text("Drop heart.json to import")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(0.12))
                    )
                    .padding(.top, 18)
            }
        }
        // Welcome panel mirrors the sidebar drop target so a brand-new user
        // doesn't have to aim at the sidebar at all.
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private func quickStartRow(number: Int,
                               title: String,
                               detail: String,
                               code: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let code {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.secondary.opacity(0.12))
                        )
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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

            // Tab bar — fixed list, no close/+. Only switches active tab.
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
        let isRunning = processManager.status(id).isRunning
        ZStack {
            // Terminal layer — always rendered so the persistent SwiftTerm view stays mounted
            // (preserves cursor / scrollback / TUI state across tab switches).
            ZStack {
                OutputView(terminalView: processManager.terminalView(for: id))
                if !isRunning {
                    activateOverlay(task: task)
                }
            }
            .opacity(active == .terminal ? 1 : 0)
            .allowsHitTesting(active == .terminal)

            // Browser layer — only present when this task has a URL.
            if availableTabs.contains(.browser), let url = task.url {
                BrowserView(url: url)
                    .id("browser-\(id)")
                    .opacity(active == .browser ? 1 : 0)
                    .allowsHitTesting(active == .browser)
            }
        }
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

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field(label: "Name") {
                        styledTextField(placeholder: "My dev server", text: $name)
                    }

                    field(label: "Command") {
                        styledTextField(
                            placeholder: "npm run dev",
                            text: $command,
                            monospaced: true
                        )
                    }

                    field(label: "Working directory",
                          hint: "Where the command runs. Tilde (~) expands to your home folder.") {
                        directoryRow
                    }

                    HStack(alignment: .top, spacing: 16) {
                        field(label: "Port",
                              hint: "Optional. Enables the KILL PORT button and readiness check.") {
                            styledTextField(placeholder: "3000", text: $portText, monospaced: true)
                                .frame(width: 140)
                                .onChange(of: portText) { new in
                                    let filtered = new.filter(\.isNumber)
                                    if filtered != new { portText = filtered }
                                }
                        }

                        field(label: "Folder",
                              hint: "Optional. Use “/” for nested folders, e.g. Backend/Workers.") {
                            styledTextField(placeholder: "Backend", text: $folder)
                        }
                    }

                    field(label: "URL",
                          hint: "Optional. Adds a globe icon to open this URL in the in-app browser.") {
                        styledTextField(placeholder: "http://localhost:3000",
                                        text: $url,
                                        monospaced: true)
                    }

                    Toggle(isOn: $isClaudeShortcut) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.purple)
                                Text("Claude shortcut")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            Text("Pins this task at the top of the sidebar and lets you open multiple parallel terminal sessions for it (e.g. several `claude` chats in the same dir).")
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
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            Divider()

            footer
        }
        .frame(width: 560, height: 620)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - sections

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: "pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Edit task")
                    .font(.system(size: 16, weight: .semibold))
                Text(verbatim: "id: \(task.id)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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
            Button("Save changes") { commit() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding(.horizontal, 24)
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

struct DropZoneView: View {
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(isTargeted
                 ? "Drop to import as folder"
                 : "Drop or click to import a tasks.json as folder")
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

struct PendingImport: Identifiable {
    let id = UUID()
    let tasks: [DevTask]
    let suggestedName: String
    let sourceFile: String
}

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
                Text("Import as folder")
                    .font(.title3.bold())
            }

            Text("Found \(pending.tasks.count) task(s) in \(pending.sourceFile). Group them under a folder name:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Folder name", text: $folderName)
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
        .onAppear {
            folderName = pending.suggestedName
        }
    }

    private func confirm() {
        let trimmed = folderName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
    }
}

private extension String {
    /// Returns nil when the string is empty — useful for converting empty form
    /// fields into truly absent optionals at the boundary.
    func nilIfEmpty() -> String? { isEmpty ? nil : self }
}
