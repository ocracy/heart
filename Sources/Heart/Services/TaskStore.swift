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

    private let fileURL: URL
    private let sourcesURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Heart", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        self.fileURL = dir.appendingPathComponent("tasks.json")
        self.sourcesURL = dir.appendingPathComponent("sources.json")

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
            // The previous `try?` pair was swallowing this — and that's exactly
            // what caused "I deleted a task and it came back after restart":
            // the encode/write failed (e.g. transient file-system error) but
            // the in-memory list looked correct, so the next launch read the
            // pre-deletion file off disk. Logging via NSLog so it shows up in
            // Console.app under "Heart".
            NSLog("[TaskStore] save failed (path=%@, taskCount=%d): %@",
                  fileURL.path, tasks.count, "\(error)")
        }
    }

    func update(_ updated: [DevTask]) {
        self.tasks = updated
        save()
    }

    func remove(id: String) {
        tasks.removeAll { $0.id == id }
        save()
    }

    /// Replace a single task (matched by id) and persist. No-op if id not found.
    func upsert(_ task: DevTask) {
        if let idx = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[idx] = task
        } else {
            tasks.append(task)
        }
        save()
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
                t.folder = nil
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

    var configPath: String { fileURL.path }

    /// Generic placeholders so the app is usable out of the box.
    /// Project-specific configs ship in `tasks.example.json` (Settings → Import).
    static var defaults: [DevTask] {
        let home = NSHomeDirectory()
        return [
            DevTask(id: "example-http",
                    name: "Example: HTTP server",
                    command: "python3 -m http.server 8000",
                    cwd: home,
                    port: 8000),
            DevTask(id: "example-watch",
                    name: "Example: Watch logs",
                    command: "tail -f /var/log/system.log",
                    cwd: home)
        ]
    }
}
