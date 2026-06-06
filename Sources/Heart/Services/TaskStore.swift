import Foundation
import Combine

/// Saved URL the user wants quick access to when adding a Browser task.
/// Stored globally (cross-project) in `bookmarks.json` so the library follows
/// the user, not the project.
struct Bookmark: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var icon: String?

    init(id: String = UUID().uuidString, name: String, url: String, icon: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.icon = icon
    }
}

/// A saved cwd that the detail-bar "+" button can spawn a fresh terminal at.
/// Cross-project, persisted globally in `terminal-shortcuts.json` — these
/// follow the user, not any one project. `name` is purely cosmetic (defaults
/// to the path basename when blank).
struct TerminalShortcut: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String

    init(id: String = UUID().uuidString, name: String = "", path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    /// User-facing label. Falls back to the cwd basename so blank entries
    /// don't render as empty rows in the "+ Terminal" menu.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let expanded = (path as NSString).expandingTildeInPath
        let base = (expanded as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }
}

/// On-disk shape of a single project file (`projects/<id>.json`). Each project
/// is fully self-contained: its tasks, its imported source path, its own
/// folder ordering and explicitly-remembered (empty) subfolders. Folder strings
/// inside ProjectFile are **project-local** — i.e. `"Frontend/Workers"` not
/// `"Maatrics/Frontend/Workers"`. The project name is implicit (it's `name`).
struct ProjectFile: Codable {
    var schemaVersion: Int = 1
    var id: String
    var name: String
    var tasks: [DevTask]
    var rememberedFolders: [String] = []
    /// Parent path (project-local; `""` = project root) → ordered child folder names.
    var folderOrder: [String: [String]] = [:]
    /// Absolute path of the heart.json this project was imported from, if any.
    var bundleSource: String?
}

/// `projects.json` — index file listing project ids in tab order.
struct ProjectIndex: Codable {
    var schemaVersion: Int = 1
    var order: [String]
}

/// Node in the folder tree. Reference type so we can mutate `subfolders`/`tasks` while building.
final class FolderNode {
    let name: String
    let path: String
    var subfolders: [FolderNode] = []
    var tasks: [DevTask] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    /// All tasks at this node and below — used for aggregate start/stop on a folder.
    func allTasks() -> [DevTask] {
        var result = tasks
        for sub in subfolders {
            result.append(contentsOf: sub.allTasks())
        }
        return result
    }
}

final class TaskStore: ObservableObject {
    @Published var tasks: [DevTask] = []
    /// folder name → absolute path of the heart.json that imported it.
    /// Used to power the folder's right-click "Save" so the user doesn't have
    /// to re-pick the destination file every time.
    @Published var bundleSources: [String: String] = [:]
    /// Persisted tab order. Always reflects the canonical UI order of projects.
    /// New projects get appended; projects that exist in `tasks` but not here are
    /// auto-appended on read (see `orderedProjects`).
    @Published var projectOrder: [String] = []
    /// Folder paths the user explicitly created via the UI (Add folder…). Needed
    /// because the folder tree is otherwise derived from task `folder` values —
    /// so an empty folder (no tasks under it) would simply not render. Storing
    /// the path here keeps the empty folder visible until the user deletes it.
    @Published var rememberedFolders: Set<String> = []
    /// Manual ordering of subfolders under a parent path. Keyed by parent path
    /// (project name for top-level folders, parent absolute path for nested).
    /// Value is the ordered list of immediate child folder names. Missing keys
    /// fall back to alphabetical / insertion order.
    @Published var folderOrder: [String: [String]] = [:]
    /// Saved URL library shown in the "+ Browser" menu. Cross-project, persisted
    /// globally to `bookmarks.json` so the list survives project deletions.
    @Published var bookmarks: [Bookmark] = []
    /// Saved cwds for the detail-bar "+" → Terminal menu. Cross-project,
    /// persisted globally to `terminal-shortcuts.json`. Lets the user spawn
    /// throwaway terminals at a known directory with one click.
    @Published var terminalShortcuts: [TerminalShortcut] = []

    static let defaultProjectName = "Project 1"

    private let baseDir: URL
    private let fileURL: URL            // legacy tasks.json (post-migration: removed)
    private let sourcesURL: URL         // legacy sources.json (post-migration: split into ProjectFile.bundleSource)
    private let projectsURL: URL        // index of project ids in tab order
    private let foldersURL: URL         // legacy folders.json (post-migration: split into ProjectFile.rememberedFolders)
    private let folderOrderURL: URL     // legacy folder-order.json (post-migration: split into ProjectFile.folderOrder)
    private let bookmarksURL: URL
    private let terminalShortcutsURL: URL
    private let projectsDir: URL        // per-project files live here
    private let trashDir: URL           // deleted projects archived here

    /// Display-name → project id (slug + hex). Built during load/migration.
    /// id is the filename stem in `projects/<id>.json`. Renaming a project only
    /// touches `ProjectFile.name`; the id never changes.
    private var projectIdsByName: [String: String] = [:]

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Heart", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.baseDir = dir
        self.fileURL = dir.appendingPathComponent("tasks.json")
        self.sourcesURL = dir.appendingPathComponent("sources.json")
        self.projectsURL = dir.appendingPathComponent("projects.json")
        self.foldersURL = dir.appendingPathComponent("folders.json")
        self.folderOrderURL = dir.appendingPathComponent("folder-order.json")
        self.bookmarksURL = dir.appendingPathComponent("bookmarks.json")
        self.terminalShortcutsURL = dir.appendingPathComponent("terminal-shortcuts.json")
        self.projectsDir = dir.appendingPathComponent("projects", isDirectory: true)
        self.trashDir = self.projectsDir.appendingPathComponent(".trash", isDirectory: true)

        // One-time migration: if Heart's tasks.json doesn't exist yet but the legacy
        // Stoker config does, copy it over so users keep their setup after the rename.
        if !fm.fileExists(atPath: fileURL.path) {
            let legacy = appSupport
                .appendingPathComponent("Stoker", isDirectory: true)
                .appendingPathComponent("tasks.json")
            if fm.fileExists(atPath: legacy.path) {
                try? fm.copyItem(at: legacy, to: fileURL)
            }
        }

        loadBookmarks()
        loadTerminalShortcuts()
        // Per-project files: if `projects/` exists, that's the truth. Otherwise
        // migrate the legacy single tasks.json into per-project files.
        if fm.fileExists(atPath: projectsDir.path) {
            loadAllProjects()
        } else if fm.fileExists(atPath: fileURL.path) {
            migrateLegacyTasksJSON()
        } else {
            // First-ever launch — seed defaults into "Project 1".
            try? fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            self.tasks = Self.defaults
            ensureProjectInOrder(Self.defaultProjectName)
            saveAllProjects()
        }
    }

    /// Walk `projects/` and rebuild in-memory state (tasks, bundleSources,
    /// rememberedFolders, folderOrder, projectIdsByName) from the per-project files.
    private func loadAllProjects() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: projectsDir,
                                                       includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles]) else {
            return
        }
        var allTasks: [DevTask] = []
        var allSources: [String: String] = [:]
        var allRemembered: Set<String> = []
        var allFolderOrder: [String: [String]] = [:]
        var idsByName: [String: String] = [:]
        var filesById: [String: ProjectFile] = [:]

        for entry in entries where entry.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entry),
                  let file = try? JSONDecoder().decode(ProjectFile.self, from: data) else {
                continue
            }
            filesById[file.id] = file
        }

        // Re-read persisted projectOrder index. Anything in the index that has
        // a matching file is appended in index order; remaining files come last.
        var orderedIds: [String] = []
        if let data = try? Data(contentsOf: projectsURL),
           let decoded = try? JSONDecoder().decode(ProjectIndex.self, from: data) {
            for id in decoded.order where filesById[id] != nil {
                orderedIds.append(id)
            }
        }
        for id in filesById.keys where !orderedIds.contains(id) {
            orderedIds.append(id)
        }

        var orderNames: [String] = []
        for id in orderedIds {
            guard let file = filesById[id] else { continue }
            idsByName[file.name] = id
            orderNames.append(file.name)
            // Re-base each task's folder back to the legacy global shape
            // (project name + "/" + subfolder) so internal readers — which still
            // expect that format — keep working without code changes.
            for task in file.tasks {
                var t = task
                let sub = DevTask.subfolderPath(t.folder)
                t.folder = sub.map { "\(file.name)/\($0)" } ?? file.name
                allTasks.append(t)
            }
            for sub in file.rememberedFolders {
                let s = sub.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if s.isEmpty {
                    allRemembered.insert(file.name)
                } else {
                    allRemembered.insert("\(file.name)/\(s)")
                }
            }
            // folderOrder key in ProjectFile uses "" for the project root and
            // subfolder-relative paths otherwise; rehydrate back to absolute paths.
            for (key, children) in file.folderOrder {
                let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let absoluteKey = k.isEmpty ? file.name : "\(file.name)/\(k)"
                allFolderOrder[absoluteKey] = children
            }
            if let src = file.bundleSource {
                allSources[file.name] = src
            }
        }

        self.tasks = allTasks
        self.bundleSources = allSources
        self.rememberedFolders = allRemembered
        self.folderOrder = allFolderOrder
        self.projectIdsByName = idsByName
        self.projectOrder = orderNames
        // Empty (no-task, no-folder) projects: the loop above already added them
        // via `orderNames` so the tab bar will surface them.
    }

    /// First-launch-after-upgrade: split the single `tasks.json` into
    /// `projects/<id>.json` files, then archive the legacy files as `.bak`.
    private func migrateLegacyTasksJSON() {
        let fm = FileManager.default
        // Decode legacy state.
        let legacyTasks: [DevTask] = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([DevTask].self, from: $0) } ?? Self.defaults
        let legacyOrder: [String] = (try? Data(contentsOf: projectsURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let legacySources: [String: String] = (try? Data(contentsOf: sourcesURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let legacyFolders: [String] = (try? Data(contentsOf: foldersURL))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let legacyFolderOrder: [String: [String]] = (try? Data(contentsOf: folderOrderURL))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]

        try? fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        // Populate live state — keep folder strings in the legacy global shape
        // (project/subfolder) so the rest of the code works unchanged. The
        // per-project files we write below use the subfolder-only shape.
        self.tasks = legacyTasks
        self.bundleSources = legacySources
        self.rememberedFolders = Set(legacyFolders)
        self.folderOrder = legacyFolderOrder
        self.projectOrder = legacyOrder
        migrateNilFolders()

        // Allocate ids for every discovered project, then write its file.
        let projects = derivedProjects()
        for name in projects {
            let id = allocateProjectId(for: name)
            projectIdsByName[name] = id
            writeProjectFile(name: name, id: id)
        }
        // Reorder index to match `legacyOrder` where possible, then anything new.
        var ids: [String] = []
        var seen: Set<String> = []
        for name in legacyOrder {
            if let id = projectIdsByName[name], !seen.contains(id) {
                ids.append(id); seen.insert(id)
            }
        }
        for name in projects {
            if let id = projectIdsByName[name], !seen.contains(id) {
                ids.append(id); seen.insert(id)
            }
        }
        writeProjectIndex(orderedIds: ids)

        // Archive legacy files so the user can roll back manually.
        for url in [fileURL, sourcesURL, foldersURL, folderOrderURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            let bak = url.appendingPathExtension("bak")
            _ = try? fm.removeItem(at: bak)
            _ = try? fm.moveItem(at: url, to: bak)
        }
        // The old projects.json was an order-only list of names; we rewrote it
        // above with the new schema. Keep a .legacy.bak for paranoia.
        // (writeProjectIndex already overwrote it; we already archived above.)
    }

    func load() {
        // Legacy entrypoint preserved for callers; loadAllProjects is what we
        // actually use now. Reload from disk by re-running the project loader.
        loadAllProjects()
    }

    private func loadSources() {
        guard let data = try? Data(contentsOf: sourcesURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        self.bundleSources = decoded
    }

    private func saveSources() {
        // Post-refactor: bundleSource lives inside each ProjectFile. The
        // legacy `sources.json` is not re-created. Callers continue to mutate
        // `bundleSources` in memory; the actual on-disk update happens through
        // saveAllProjects() (invoked by save()).
        saveAllProjects()
    }

    private func loadProjectOrder() {
        guard let data = try? Data(contentsOf: projectsURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        self.projectOrder = decoded
    }

    private func saveProjectOrder() {
        // Post-refactor: tab order is the index of ids in `projects.json`. The
        // canonical write path is `writeProjectIndex` via saveAllProjects().
        saveAllProjects()
    }

    private func loadFolderOrder() {
        guard let data = try? Data(contentsOf: folderOrderURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        self.folderOrder = decoded
    }

    private func saveFolderOrder() {
        // Post-refactor: per-project folderOrder lives inside each ProjectFile.
        saveAllProjects()
    }

    private func loadBookmarks() {
        guard let data = try? Data(contentsOf: bookmarksURL),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            return
        }
        self.bookmarks = decoded
    }

    private func saveBookmarks() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(bookmarks)
            try data.write(to: bookmarksURL, options: .atomic)
        } catch {
            NSLog("[TaskStore] saveBookmarks failed: %@", "\(error)")
        }
    }

    /// Add a bookmark to the library. De-duped by trimmed URL — re-saving the
    /// same URL just updates the existing entry's name/icon in place so the
    /// menu doesn't grow duplicates after repeated "Save as bookmark" clicks.
    func addBookmark(name: String, url: String, icon: String? = nil) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = bookmarks.firstIndex(where: { $0.url == trimmedURL }) {
            bookmarks[idx].name = trimmedName.isEmpty ? bookmarks[idx].name : trimmedName
            if let icon { bookmarks[idx].icon = icon }
        } else {
            bookmarks.append(Bookmark(name: trimmedName.isEmpty ? trimmedURL : trimmedName,
                                      url: trimmedURL,
                                      icon: icon))
        }
        saveBookmarks()
    }

    func removeBookmark(id: String) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    // MARK: - Terminal shortcuts (cwds for the detail-bar "+" → Terminal menu)

    private func loadTerminalShortcuts() {
        guard let data = try? Data(contentsOf: terminalShortcutsURL),
              let decoded = try? JSONDecoder().decode([TerminalShortcut].self, from: data) else {
            return
        }
        self.terminalShortcuts = decoded
    }

    private func saveTerminalShortcuts() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(terminalShortcuts)
            try data.write(to: terminalShortcutsURL, options: .atomic)
        } catch {
            NSLog("[TaskStore] saveTerminalShortcuts failed: %@", "\(error)")
        }
    }

    /// Append a new shortcut. De-duped by trimmed path — re-adding the same
    /// path just updates the existing entry's name in place. Returns the id
    /// of the (new or updated) shortcut.
    @discardableResult
    func addTerminalShortcut(name: String, path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = terminalShortcuts.firstIndex(where: { $0.path == trimmedPath }) {
            if !trimmedName.isEmpty { terminalShortcuts[idx].name = trimmedName }
            saveTerminalShortcuts()
            return terminalShortcuts[idx].id
        }
        let shortcut = TerminalShortcut(name: trimmedName, path: trimmedPath)
        terminalShortcuts.append(shortcut)
        saveTerminalShortcuts()
        return shortcut.id
    }

    func updateTerminalShortcut(id: String, name: String, path: String) {
        guard let idx = terminalShortcuts.firstIndex(where: { $0.id == id }) else { return }
        terminalShortcuts[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        terminalShortcuts[idx].path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        saveTerminalShortcuts()
    }

    func removeTerminalShortcut(id: String) {
        terminalShortcuts.removeAll { $0.id == id }
        saveTerminalShortcuts()
    }

    private func loadRememberedFolders() {
        guard let data = try? Data(contentsOf: foldersURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        self.rememberedFolders = Set(decoded)
    }

    private func saveRememberedFolders() {
        // Post-refactor: per-project rememberedFolders lives inside each ProjectFile.
        saveAllProjects()
    }

    /// Remember which file a folder was imported from (used for "Save" overwrite).
    func setBundleSource(folder: String, path: String) {
        bundleSources[folder] = path
        saveSources()
    }

    func bundleSource(forFolder folder: String) -> String? {
        bundleSources[folder]
    }

    func clearBundleSource(forFolder folder: String) {
        bundleSources.removeValue(forKey: folder)
        saveSources()
    }

    func save() {
        // Global save — fan out to every known project file. Used by paths that
        // don't know which project(s) they touched (e.g. legacy callers).
        saveAllProjects()
    }

    /// Write only the file backing `projectName`. Preferred over `save()` when
    /// we know which project was mutated — keeps mtime stable on every other
    /// project's file (so per-project file copies + diffs stay clean).
    func saveProject(_ projectName: String) {
        let id = projectIdsByName[projectName] ?? allocateProjectId(for: projectName)
        projectIdsByName[projectName] = id
        writeProjectFile(name: projectName, id: id)
        // Sync the index — projects.json should reflect projectOrder of ids.
        let ids = projectOrder.compactMap { projectIdsByName[$0] }
        writeProjectIndex(orderedIds: ids)
    }

    /// Write every known project. Used by global save() and migrations.
    func saveAllProjects() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: projectsDir.path) {
            try? fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        }
        let projects = derivedProjects()
        // Allocate ids for any project that doesn't have one yet.
        for name in projects where projectIdsByName[name] == nil {
            projectIdsByName[name] = allocateProjectId(for: name)
        }
        let activeNames = Set(projects)
        let activeIds = Set(projects.compactMap { projectIdsByName[$0] })

        // Archive any project files on disk whose project is no longer in
        // memory (rename → .trash/<id>.<epoch>.json.deleted). This is what
        // makes "delete project" actually remove the file.
        if let entries = try? fm.contentsOfDirectory(at: projectsDir,
                                                    includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]) {
            for entry in entries where entry.pathExtension == "json" {
                let id = entry.deletingPathExtension().lastPathComponent
                guard !activeIds.contains(id) else { continue }
                try? fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
                let epoch = Int(Date().timeIntervalSince1970)
                let archive = trashDir.appendingPathComponent("\(id).\(epoch).json.deleted")
                _ = try? fm.moveItem(at: entry, to: archive)
            }
        }

        // Drop ids whose project no longer exists.
        for (name, _) in projectIdsByName where !activeNames.contains(name) {
            projectIdsByName.removeValue(forKey: name)
        }
        for name in projects {
            guard let id = projectIdsByName[name] else { continue }
            writeProjectFile(name: name, id: id)
        }
        let ids = projectOrder.compactMap { projectIdsByName[$0] }
        writeProjectIndex(orderedIds: ids)
    }

    /// Slug-based id (`<slug>-<hex4>`). Collision-proof because the random
    /// suffix means two projects named identically still get unique filenames.
    private func allocateProjectId(for name: String) -> String {
        let lower = name.lowercased()
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let cleaned = lower.map { ch -> Character in
            allowed.contains(ch) ? ch : "-"
        }
        let collapsed = String(cleaned)
            .split(separator: "-")
            .joined(separator: "-")
        let slug = collapsed.isEmpty ? "project" : collapsed
        let hex = String(format: "%04x", Int.random(in: 0..<0x10000))
        return "\(slug)-\(hex)"
    }

    private func writeProjectFile(name: String, id: String) {
        // Collect project-local task list. Strip the project-name prefix from
        // `folder` so the file stores subfolder-only paths.
        let prefix = name + "/"
        let projectTasks: [DevTask] = tasks.compactMap { task in
            guard let folder = task.folder else { return nil }
            if folder == name {
                var t = task
                t.folder = nil
                return t
            }
            if folder.hasPrefix(prefix) {
                var t = task
                t.folder = String(folder.dropFirst(prefix.count))
                return t
            }
            return nil
        }
        let projectRemembered: [String] = rememberedFolders.compactMap { path in
            if path == name { return "" }
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            return nil
        }.filter { !$0.isEmpty }
        var projectFolderOrder: [String: [String]] = [:]
        for (key, children) in folderOrder {
            if key == name {
                projectFolderOrder[""] = children
            } else if key.hasPrefix(prefix) {
                projectFolderOrder[String(key.dropFirst(prefix.count))] = children
            }
        }
        let file = ProjectFile(
            schemaVersion: 1,
            id: id,
            name: name,
            tasks: projectTasks,
            rememberedFolders: projectRemembered,
            folderOrder: projectFolderOrder,
            bundleSource: bundleSources[name]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(file)
            let dest = projectsDir.appendingPathComponent("\(id).json")
            let tmp = dest.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            NSLog("[TaskStore] writeProjectFile failed (id=%@): %@", id, "\(error)")
        }
    }

    private func writeProjectIndex(orderedIds: [String]) {
        let index = ProjectIndex(schemaVersion: 1, order: orderedIds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(index)
            try data.write(to: projectsURL, options: .atomic)
        } catch {
            NSLog("[TaskStore] writeProjectIndex failed: %@", "\(error)")
        }
    }

    /// Absolute filesystem path of `projects/<id>.json` for the given project.
    /// Used by SettingsView for "Open in Finder" and the path display header.
    func projectFilePath(_ projectName: String) -> String? {
        guard let id = projectIdsByName[projectName] else { return nil }
        return projectsDir.appendingPathComponent("\(id).json").path
    }

    func update(_ updated: [DevTask]) {
        self.tasks = updated
        migrateNilFolders()
        save()
        syncProjectOrder()
    }

    func remove(id: String) {
        tasks.removeAll { $0.id == id }
        save()
        syncProjectOrder()
    }

    /// Replace a single task (matched by id) and persist. No-op if id not found.
    func upsert(_ task: DevTask) {
        var t = task
        if (t.folder?.trimmingCharacters(in: .whitespacesAndNewlines)).map({ $0.isEmpty }) ?? true {
            t.folder = orderedProjects.first ?? Self.defaultProjectName
        }
        if let idx = tasks.firstIndex(where: { $0.id == t.id }) {
            tasks[idx] = t
        } else {
            tasks.append(t)
        }
        save()
        syncProjectOrder()
    }

    /// Append decoded tasks. The prompted `outerFolder` is the parent; if a task already
    /// declares its own `folder` in JSON, that becomes a sub-folder nested under
    /// `outerFolder` (joined with `/`). Conflicting IDs get a suffix so nothing is overwritten.
    func append(_ newTasks: [DevTask], folder outerFolder: String?) {
        let existing = Set(tasks.map(\.id))
        var seen = existing
        var appended: [DevTask] = []

        let outer = outerFolder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outerPath: String? = (outer?.isEmpty == false) ? outer : nil

        for task in newTasks {
            var t = task
            let inner = t.folder?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let hasInner = (inner?.isEmpty == false)
            switch (outerPath, hasInner ? inner : nil) {
            case let (outer?, inner?):
                t.folder = "\(outer)/\(inner)"
            case let (outer?, nil):
                t.folder = outer
            case let (nil, inner?):
                t.folder = inner
            case (nil, nil):
                // No outer + no inner is invalid in the new model — drop into the default project.
                t.folder = orderedProjects.first ?? Self.defaultProjectName
            }

            var id = t.id
            var bump = 2
            while seen.contains(id) {
                id = "\(t.id)-\(bump)"
                bump += 1
            }
            t.id = id
            seen.insert(id)
            appended.append(t)
        }
        tasks.append(contentsOf: appended)
        save()
        // Append the new top-level project to the tab order if we haven't seen it before.
        if let project = topLevelSegment(of: outerPath) {
            ensureProjectInOrder(project)
        }
    }

    func removeFolder(path: String) {
        let prefix = path + "/"
        tasks.removeAll { task in
            guard let folder = task.folder else { return false }
            return folder == path || folder.hasPrefix(prefix)
        }
        // Also drop any remembered source path so a fresh import of a different
        // file with the same name doesn't accidentally save back to the old one.
        if bundleSources.removeValue(forKey: path) != nil {
            saveSources()
        }
        // Drop the folder itself + every subfolder from the remembered set.
        let before = rememberedFolders.count
        rememberedFolders = rememberedFolders.filter {
            !($0 == path || $0.hasPrefix(prefix))
        }
        if rememberedFolders.count != before {
            saveRememberedFolders()
        }
        // If we just deleted a whole project, drop it from the tab order too.
        if topLevelSegment(of: path) == path,
           let idx = projectOrder.firstIndex(of: path) {
            projectOrder.remove(at: idx)
            saveProjectOrder()
        }
        save()
    }

    func tasksUnder(path: String) -> [DevTask] {
        let prefix = path + "/"
        return tasks.filter { task in
            guard let folder = task.folder else { return false }
            return folder == path || folder.hasPrefix(prefix)
        }
    }

    /// Build a hierarchical tree of folders + tasks. Claude shortcuts are placed in the
    /// tree alongside regular tasks (so they get scoped under each imported bundle's folder),
    /// but render with a different row style.
    /// `folder` values may be slash-separated paths (e.g. "Maatrics/Frontend") for nesting.
    /// Empty folders that the user created via "Add folder" are also rendered (see
    /// `rememberedFolders`).
    func buildTree() -> FolderNode {
        buildTreeBase(includeQuickActions: true)
    }

    /// Sub-tree of a single project — the project name is the implicit root
    /// (returned node has `name == project`, `path == project`).
    /// Quick-action tasks are filtered out here because they're surfaced as chips
    /// above the sidebar, not as rows inside it.
    func buildTree(forProject project: String) -> FolderNode {
        let full = buildTreeExcludingQuickActions()
        if let match = full.subfolders.first(where: { $0.name == project }) {
            return match
        }
        return FolderNode(name: project, path: project)
    }

    /// All quick-action tasks belonging to a project (top-level + nested folders).
    func quickActions(forProject project: String) -> [DevTask] {
        tasksUnder(project: project).filter { $0.isQuickAction }
    }

    /// Variant of `buildTree` used by per-project sidebar rendering — keeps the
    /// nesting logic identical but skips quick-action tasks.
    private func buildTreeExcludingQuickActions() -> FolderNode {
        buildTreeBase(includeQuickActions: false)
    }

    private func buildTreeBase(includeQuickActions: Bool) -> FolderNode {
        let root = FolderNode(name: "", path: "")
        // Seed the tree with explicitly-created empty folders first, so they
        // render even when no tasks are inside them yet.
        for path in rememberedFolders {
            ensurePath(path, in: root)
        }
        for task in tasks where includeQuickActions || !task.isQuickAction {
            let raw = task.folder?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if raw.isEmpty {
                root.tasks.append(task)
                continue
            }
            let node = ensurePath(raw, in: root)
            node.tasks.append(task)
        }
        sortTree(root)
        return root
    }

    /// Sort every subfolder list against `folderOrder` and every task list
    /// against `task.order`. Both fall back to insertion / alphabetical when
    /// the user hasn't manually reordered.
    private func sortTree(_ node: FolderNode) {
        let ordering = folderOrder[node.path] ?? []
        node.subfolders.sort { a, b in
            let ai = ordering.firstIndex(of: a.name)
            let bi = ordering.firstIndex(of: b.name)
            switch (ai, bi) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true   // explicitly-ordered first
            case (nil, _?):    return false
            case (nil, nil):   return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        node.tasks.sort { a, b in
            switch (a.order, b.order) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
        for sub in node.subfolders { sortTree(sub) }
    }

    // MARK: - Reorder API

    /// Persist a new order for the subfolders directly under `parent`. The list
    /// is the ordered child folder names (not full paths).
    func reorderSubfolders(parent: String, names: [String]) {
        folderOrder[parent] = names
        saveFolderOrder()
        objectWillChange.send()
    }

    /// Persist a new order for the tasks directly under `folder`. Assigns a
    /// numeric `order` value spaced out so future inserts don't require
    /// renumbering. `taskIds` should be the IDs in their new desired order.
    func reorderTasks(inFolder folder: String, taskIds: [String]) {
        let stride: Double = 100
        for (idx, id) in taskIds.enumerated() {
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
            tasks[i].order = Double(idx + 1) * stride
        }
        save()
    }

    /// Walks (and lazily extends) the folder tree so that the path exists.
    /// Returns the deepest node along that path.
    @discardableResult
    private func ensurePath(_ rawPath: String, in root: FolderNode) -> FolderNode {
        let segments = rawPath.split(separator: "/").map(String.init)
        var current = root
        for (index, segment) in segments.enumerated() {
            let path = segments[0...index].joined(separator: "/")
            if let existing = current.subfolders.first(where: { $0.name == segment }) {
                current = existing
            } else {
                let node = FolderNode(name: segment, path: path)
                current.subfolders.append(node)
                current = node
            }
        }
        return current
    }

    // MARK: - Folder mutation API

    /// Create an empty folder at the given absolute path (e.g. "MyProject/Backend").
    /// No-op if the path already exists. The folder is persisted so it stays in
    /// the tree even when no tasks live under it yet.
    func addFolder(path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }
        if rememberedFolders.insert(trimmed).inserted {
            saveRememberedFolders()
        }
        // If this folder is at the top level it also implies a project — make
        // sure the tab order picks it up.
        if let project = topLevelSegment(of: trimmed) {
            ensureProjectInOrder(project)
        }
        objectWillChange.send()
    }

    /// Rename a folder (and every nested folder underneath it). Tasks whose
    /// `folder` starts with the old prefix are rewritten in place. Returns the
    /// final new path (de-duplicated against existing siblings).
    @discardableResult
    func renameFolder(oldPath: String, newPath: String) -> String {
        let oldTrimmed = oldPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let newTrimmed = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !oldTrimmed.isEmpty, !newTrimmed.isEmpty, oldTrimmed != newTrimmed else {
            return oldTrimmed
        }
        // If oldPath is a top-level project, route through renameProject so
        // bundleSources keys + projectOrder also get updated.
        if topLevelSegment(of: oldTrimmed) == oldTrimmed {
            return renameProject(oldTrimmed, to: newTrimmed)
        }

        let oldPrefix = oldTrimmed + "/"
        // Rewrite task folder prefixes.
        for idx in tasks.indices {
            guard let f = tasks[idx].folder else { continue }
            if f == oldTrimmed {
                tasks[idx].folder = newTrimmed
            } else if f.hasPrefix(oldPrefix) {
                tasks[idx].folder = newTrimmed + "/" + f.dropFirst(oldPrefix.count)
            }
        }
        // Rewrite remembered folder entries.
        let updated: Set<String> = Set(rememberedFolders.map { path -> String in
            if path == oldTrimmed { return newTrimmed }
            if path.hasPrefix(oldPrefix) {
                return newTrimmed + "/" + path.dropFirst(oldPrefix.count)
            }
            return path
        })
        if updated != rememberedFolders {
            rememberedFolders = updated
            saveRememberedFolders()
        }
        save()
        return newTrimmed
    }

    /// Move a task into a different folder (absolute path, e.g.
    /// "MyProject/Backend/Workers"). Empty `newFolder` puts it at the project
    /// root — but callers should always pass the project name as the prefix
    /// since folder=nil isn't a valid state anymore.
    func moveTask(id: String, toFolder newFolder: String) {
        let trimmed = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].folder = trimmed.isEmpty ? nil : trimmed
        save()
        syncProjectOrder()
    }

    var configPath: String { fileURL.path }

    // MARK: - Project-level API

    /// Canonical UI order of projects. Starts from the persisted `projectOrder`
    /// (so manual reorder is honored), then appends any projects discovered from
    /// task folders that aren't in the order yet. Stale entries (orphan project
    /// names with no tasks) are filtered out.
    var orderedProjects: [String] {
        let derived = derivedProjects()
        let derivedSet = Set(derived)
        var result: [String] = []
        var seen = Set<String>()
        for name in projectOrder where derivedSet.contains(name) && !seen.contains(name) {
            result.append(name)
            seen.insert(name)
        }
        for name in derived where !seen.contains(name) {
            result.append(name)
            seen.insert(name)
        }
        return result
    }

    func tasksUnder(project: String) -> [DevTask] {
        tasksUnder(path: project)
    }

    /// Rename a top-level project. Updates every task's `folder` prefix, the
    /// remembered source path key, and the persisted project order.
    /// Returns the actual final name (de-duplicated against existing projects).
    @discardableResult
    func renameProject(_ old: String, to new: String) -> String {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, trimmed != old else { return old }
        let existingProjects = Set(derivedProjects()).subtracting([old])
        let finalName = uniqueProjectName(base: trimmed, taken: existingProjects)

        let prefix = old + "/"
        for idx in tasks.indices {
            guard let folder = tasks[idx].folder else { continue }
            if folder == old {
                tasks[idx].folder = finalName
            } else if folder.hasPrefix(prefix) {
                tasks[idx].folder = finalName + "/" + folder.dropFirst(prefix.count)
            }
        }
        if let source = bundleSources.removeValue(forKey: old) {
            bundleSources[finalName] = source
            saveSources()
        }
        if let idx = projectOrder.firstIndex(of: old) {
            projectOrder[idx] = finalName
        } else {
            projectOrder.append(finalName)
        }
        saveProjectOrder()
        save()
        return finalName
    }

    func reorderProjects(_ newOrder: [String]) {
        // Keep only names that actually exist; preserve any that the caller forgot.
        let known = Set(derivedProjects())
        var seen = Set<String>()
        var result: [String] = []
        for name in newOrder where known.contains(name) && !seen.contains(name) {
            result.append(name)
            seen.insert(name)
        }
        for name in derivedProjects() where !seen.contains(name) {
            result.append(name)
            seen.insert(name)
        }
        projectOrder = result
        saveProjectOrder()
    }

    /// Create a new, empty project (no tasks). Returns the chosen name (de-duplicated).
    @discardableResult
    func createEmptyProject(suggestedName: String? = nil) -> String {
        let base = (suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? nextProjectName()
        let final = uniqueProjectName(base: base, taken: Set(derivedProjects()))
        // Empty projects don't have any task rows, but we still want them to
        // appear as a tab — so persist them in `projectOrder`.
        if !projectOrder.contains(final) {
            projectOrder.append(final)
            saveProjectOrder()
        }
        return final
    }

    /// Replace all tasks of a project with a fresh set decoded from JSON. Used by
    /// drop-into-project. The whole swap is done as a single mutation of `tasks`
    /// so SwiftUI doesn't render an intermediate state where the old tasks are
    /// gone but the new ones aren't in yet — that flash was causing the
    /// sidebar to look "broken until restart" after a drop.
    /// Source URL is remembered so subsequent "Save" writes back.
    func replaceProject(_ name: String, with newTasks: [DevTask], source: URL?) {
        let prefix = name + "/"
        // Drop the current project's tasks, keep everything else.
        var nextTasks = tasks.filter { task in
            guard let folder = task.folder else { return true }
            return !(folder == name || folder.hasPrefix(prefix))
        }
        // Resolve folder paths + dedupe IDs against the surviving set.
        var seenIds = Set(nextTasks.map(\.id))
        for incoming in newTasks {
            var t = incoming
            let inner = t.folder?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let inner, !inner.isEmpty {
                t.folder = "\(name)/\(inner)"
            } else {
                t.folder = name
            }
            var id = t.id
            var bump = 2
            while seenIds.contains(id) {
                id = "\(t.id)-\(bump)"
                bump += 1
            }
            t.id = id
            seenIds.insert(id)
            nextTasks.append(t)
        }
        // Single publish — bundleSources, rememberedFolders, projectOrder side
        // effects come after so the @Published `tasks` swap is what SwiftUI
        // reacts to first.
        tasks = nextTasks

        // Drop remembered folder entries for the old contents (the dropped
        // bundle may have a different folder tree).
        let beforeCount = rememberedFolders.count
        rememberedFolders = rememberedFolders.filter { path in
            !(path == name || path.hasPrefix(prefix))
        }
        if rememberedFolders.count != beforeCount {
            saveRememberedFolders()
        }

        if let source {
            bundleSources[name] = source.path
            saveSources()
        }
        ensureProjectInOrder(name)
        save()
    }

    func unlinkSource(project: String) {
        clearBundleSource(forFolder: project)
    }

    // MARK: - Internals

    /// Top-level segment (everything before the first "/") of a folder path.
    /// nil/empty → nil.
    private func topLevelSegment(of folder: String?) -> String? {
        guard let raw = folder?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              !raw.isEmpty else { return nil }
        return raw.split(separator: "/").first.map(String.init)
    }

    /// Project names derived from current tasks (deduped, encounter order).
    private func derivedProjects() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for task in tasks {
            guard let segment = topLevelSegment(of: task.folder) else { continue }
            if seen.insert(segment).inserted {
                ordered.append(segment)
            }
        }
        // Empty projects (in projectOrder but no tasks yet) still count.
        for name in projectOrder where !seen.contains(name) {
            ordered.append(name)
            seen.insert(name)
        }
        return ordered
    }

    private func ensureProjectInOrder(_ name: String) {
        if !projectOrder.contains(name) {
            projectOrder.append(name)
            saveProjectOrder()
        }
    }

    /// Drop tasks that lost their folder reference (legacy data or hand-edited
    /// Settings JSON) into the default project so they don't disappear from the UI.
    private func migrateNilFolders() {
        let target = orderedProjects.first ?? Self.defaultProjectName
        var changed = false
        for idx in tasks.indices {
            let raw = tasks[idx].folder?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if raw.isEmpty {
                tasks[idx].folder = target
                changed = true
            }
        }
        if changed {
            ensureProjectInOrder(target)
            save()
        }
    }

    /// Pull `projectOrder` back in sync with `tasks` after a mutation that may
    /// have orphaned an entry (e.g. last task of a project deleted via Settings).
    /// Empty projects intentionally stay in the order — they're real tabs.
    private func syncProjectOrder() {
        let derived = Set(derivedProjects())
        let filtered = projectOrder.filter { derived.contains($0) }
        if filtered != projectOrder {
            projectOrder = filtered
            saveProjectOrder()
        }
    }

    /// "Project N" where N is the smallest integer not currently in use.
    private func nextProjectName() -> String {
        let existing = Set(derivedProjects())
        var n = 1
        while existing.contains("Project \(n)") {
            n += 1
        }
        return "Project \(n)"
    }

    /// Append " (2)", " (3)", … until a name isn't taken. Returns `base` if free.
    private func uniqueProjectName(base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// Public helper so import flows can pick a non-colliding project name when
    /// a dropped bundle's `name` clashes with an existing tab. Returns `base`
    /// untouched if no project owns that name yet, otherwise appends " (N)".
    func availableProjectName(base: String) -> String {
        uniqueProjectName(base: base, taken: Set(derivedProjects()))
    }

    /// Generic placeholders so the app is usable out of the box.
    /// Project-specific configs ship in `tasks.example.json` (Settings → Import).
    static var defaults: [DevTask] {
        let home = NSHomeDirectory()
        return [
            DevTask(id: "example-http",
                    name: "Example: HTTP server",
                    command: "python3 -m http.server 8000",
                    cwd: home,
                    port: 8000,
                    folder: defaultProjectName),
            DevTask(id: "example-watch",
                    name: "Example: Watch logs",
                    command: "tail -f /var/log/system.log",
                    cwd: home,
                    folder: defaultProjectName)
        ]
    }
}
