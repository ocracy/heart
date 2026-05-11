import Foundation
import Combine

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

    static let defaultProjectName = "Project 1"

    private let fileURL: URL
    private let sourcesURL: URL
    private let projectsURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Heart", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent("tasks.json")
        self.sourcesURL = dir.appendingPathComponent("sources.json")
        self.projectsURL = dir.appendingPathComponent("projects.json")

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

        load()
        loadSources()
        loadProjectOrder()
        // Folders are required — anything inherited from an older version with
        // `folder: nil` lands under "Project 1" so it shows up in a tab.
        migrateNilFolders()
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([DevTask].self, from: data) {
            self.tasks = decoded
        } else {
            self.tasks = Self.defaults
            save()
        }
    }

    private func loadSources() {
        guard let data = try? Data(contentsOf: sourcesURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        self.bundleSources = decoded
    }

    private func saveSources() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(bundleSources)
            try data.write(to: sourcesURL, options: .atomic)
        } catch {
            // Non-fatal — sources.json is just a "Save" affordance.
            NSLog("[TaskStore] saveSources failed: %@", "\(error)")
        }
    }

    private func loadProjectOrder() {
        guard let data = try? Data(contentsOf: projectsURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        self.projectOrder = decoded
    }

    private func saveProjectOrder() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(projectOrder)
            try data.write(to: projectsURL, options: .atomic)
        } catch {
            NSLog("[TaskStore] saveProjectOrder failed: %@", "\(error)")
        }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[TaskStore] save failed (path=%@, taskCount=%d): %@",
                  fileURL.path, tasks.count, "\(error)")
        }
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
    func buildTree() -> FolderNode {
        let root = FolderNode(name: "", path: "")
        for task in tasks {
            let raw = task.folder?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if raw.isEmpty {
                root.tasks.append(task)
                continue
            }
            let segments = raw.split(separator: "/").map(String.init)
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
            current.tasks.append(task)
        }
        return root
    }

    /// Sub-tree of a single project — the project name is the implicit root
    /// (returned node has `name == project`, `path == project`).
    func buildTree(forProject project: String) -> FolderNode {
        let full = buildTree()
        if let match = full.subfolders.first(where: { $0.name == project }) {
            return match
        }
        return FolderNode(name: project, path: project)
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
    /// drop-into-project. Source URL is remembered so subsequent "Save" writes back.
    func replaceProject(_ name: String, with newTasks: [DevTask], source: URL?) {
        removeFolder(path: name)
        append(newTasks, folder: name)
        if let source {
            setBundleSource(folder: name, path: source.path)
        }
        // removeFolder may have dropped the project from the order — re-add at the end.
        ensureProjectInOrder(name)
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
