import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var processManager: ProcessManager

    @State private var selectedTaskId: String?
    @State private var showSettings = false
    @State private var collapsedFolders: Set<String> = []
    @State private var isDropTargeted = false
    @State private var pendingImport: PendingImport?
    @State private var editingTask: DevTask?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 500)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    processManager.startAll(store.tasks)
                } label: {
                    Label("Start All", systemImage: "play.circle.fill")
                }
                .help("Start every task")

                Button {
                    processManager.stopAll(store.tasks)
                } label: {
                    Label("Stop All", systemImage: "stop.circle.fill")
                }
                .help("Stop every task")

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
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedTaskId) {
                let root = store.buildTree()
                ForEach(root.tasks) { task in
                    TaskRow(task: task, processManager: processManager)
                        .tag(task.id)
                        .contextMenu { rowMenu(for: task) }
                }
                ForEach(root.subfolders, id: \.path) { node in
                    folderTree(node: node, depth: 0)
                }
            }
            .listStyle(.sidebar)

            DropZoneView(isTargeted: isDropTargeted)
                .padding(8)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers: providers)
                }
                .onTapGesture {
                    pickAndImport()
                }
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
                        TaskRow(task: task, processManager: processManager)
                            .tag(task.id)
                            .contextMenu { rowMenu(for: task) }
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
                folderIconButton(systemName: "play.fill", tint: .green, help: "Start all tasks in folder") {
                    processManager.startAll(allTasks)
                }
                folderIconButton(systemName: "stop.fill", tint: .red, help: "Stop all tasks in folder") {
                    processManager.stopAll(allTasks)
                }
                folderIconButton(systemName: "arrow.clockwise", tint: .secondary, help: "Restart all tasks in folder") {
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
            Button { processManager.stopAll(allTasks) } label: {
                Label("Stop all", systemImage: "stop.fill")
            }
            Button { for task in allTasks { processManager.restart(task) } } label: {
                Label("Restart all", systemImage: "arrow.clockwise")
            }
            Divider()
            Button(role: .destructive) {
                deleteFolder(path: node.path)
            } label: {
                Label("Delete folder (\(totalCount) tasks)", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func folderIconButton(systemName: String,
                                  tint: Color,
                                  help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(tint.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(tint.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
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
        Divider()
        Button(role: .destructive) {
            deleteTask(task)
        } label: {
            Label("Delete", systemImage: "trash")
        }
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let typeId = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeId) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) else { return }
            DispatchQueue.main.async {
                presentImport(for: url)
            }
        }
        return true
    }

    private func presentImport(for url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            return
        }
        guard let decoded = try? JSONDecoder().decode([DevTask].self, from: data) else {
            return
        }
        let cleaned = decoded.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.command.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !cleaned.isEmpty else { return }
        let suggestedName = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        pendingImport = PendingImport(
            tasks: cleaned,
            suggestedName: suggestedName,
            sourceFile: url.lastPathComponent
        )
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedTaskId, let task = store.tasks.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(processManager.status(id).color)
                        .frame(width: 8, height: 8)
                    Text(task.name)
                        .font(.headline)
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
                    Button {
                        processManager.clearOutput(id)
                    } label: {
                        Label("Clear", systemImage: "eraser")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear output buffer")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)

                Divider()

                OutputView(
                    text: processManager.output(id),
                    isInteractive: processManager.status(id).isRunning,
                    onInput: { data in
                        processManager.sendInput(id, data: data)
                    }
                )
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Select a task")
                    .font(.title3)
                Text("Pick a task from the sidebar to view its output.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    @State private var folder: String
    @State private var autoStart: Bool

    init(task: DevTask, onCancel: @escaping () -> Void, onSave: @escaping (DevTask) -> Void) {
        self.task = task
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: task.name)
        _command = State(initialValue: task.command)
        _cwd = State(initialValue: task.cwd)
        _portText = State(initialValue: task.port.map { String($0) } ?? "")
        _folder = State(initialValue: task.folder ?? "")
        _autoStart = State(initialValue: task.autoStart)
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
        let port: Int? = Int(portText.trimmingCharacters(in: .whitespaces))
        let updated = DevTask(
            id: task.id,
            name: name.trimmingCharacters(in: .whitespaces),
            command: command.trimmingCharacters(in: .whitespaces),
            cwd: cwd.trimmingCharacters(in: .whitespaces),
            port: port,
            autoStart: autoStart,
            folder: trimmedFolder.isEmpty ? nil : trimmedFolder
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
