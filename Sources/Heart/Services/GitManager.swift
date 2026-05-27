import Foundation
import Combine
import AppKit

/// Per-task git repo state cache. Mirrors BrowserManager's per-task model
/// pattern: each `kind: "github"` task gets its own `GitRepoState` keyed by
/// task id, so multiple repos in the same project stay independent (one's
/// staged changes / branch / commit history don't bleed into another).
///
/// Shells out to `/usr/bin/env git` for every operation. Git CLI isn't
/// interactive, so we don't need the BSD `script` PTY wrapper used elsewhere
/// in Heart — `Process` + `Pipe` is enough.
@MainActor
final class GitManager: ObservableObject {
    @Published private(set) var states: [String: GitRepoState] = [:]
    /// Last toast-worthy push/pull/commit result per task. View polls this and
    /// shows a 3-second banner in the top bar.
    @Published var lastOpResult: [String: GitOpResult] = [:]
    /// True while a long op (push/pull) is in flight per task — drives the
    /// inline ProgressView in the top bar buttons.
    @Published private(set) var inFlight: Set<String> = []

    // MARK: - Refresh

    func refresh(taskId: String, cwd: String) async {
        let expanded = Self.expand(cwd)
        let result = await Self.runStatus(at: expanded)
        states[taskId] = result
    }

    // MARK: - Branches

    /// Local branch names, sorted by last commit time descending (newest first).
    /// Used to populate the branch dropdown in the top bar.
    func branches(cwd: String) async -> [String] {
        let expanded = Self.expand(cwd)
        let (out, _, code) = await Self.run(
            executable: "git",
            args: ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads/"],
            cwd: expanded
        )
        if code != 0 { return [] }
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// `git checkout <branch>`. If working tree changes block the checkout,
    /// surfaces git's error message as a toast.
    func checkout(taskId: String, cwd: String, branch: String) async {
        let expanded = Self.expand(cwd)
        let (out, err, code) = await Self.run(
            executable: "git",
            args: ["checkout", branch],
            cwd: expanded
        )
        if code == 0 {
            let firstLine = (err.isEmpty ? out : err)
                .split(separator: "\n").first.map(String.init)
                ?? "Switched to \(branch)"
            lastOpResult[taskId] = GitOpResult(success: true, message: firstLine)
        } else {
            let msg = (err.isEmpty ? out : err)
                .split(separator: "\n").first.map(String.init)
                ?? "Checkout failed"
            lastOpResult[taskId] = GitOpResult(success: false, message: msg)
        }
        await refresh(taskId: taskId, cwd: cwd)
    }

    /// Create a new branch.
    /// - `switchTo == true`  → `git checkout -b <name>` — the working tree
    ///   stays put but HEAD moves to the new branch, so uncommitted edits
    ///   ride along.
    /// - `switchTo == false` → `git branch <name>` — creates the branch
    ///   pointing at the current HEAD and stays on the original branch, so
    ///   the working-tree edits remain on the original branch.
    func createBranch(taskId: String, cwd: String, name: String, switchTo: Bool) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastOpResult[taskId] = GitOpResult(success: false, message: "Branch name is empty.")
            return
        }
        let expanded = Self.expand(cwd)
        let args = switchTo ? ["checkout", "-b", trimmed] : ["branch", trimmed]
        let (_, err, code) = await Self.run(executable: "git", args: args, cwd: expanded)
        if code == 0 {
            lastOpResult[taskId] = GitOpResult(
                success: true,
                message: switchTo ? "Switched to new branch '\(trimmed)'"
                                  : "Created branch '\(trimmed)' (still on original)"
            )
        } else {
            let msg = err.split(separator: "\n").first.map(String.init) ?? "Branch create failed"
            lastOpResult[taskId] = GitOpResult(success: false, message: msg)
        }
        await refresh(taskId: taskId, cwd: cwd)
    }

    // MARK: - Diff

    func diff(cwd: String, path: String, staged: Bool) async -> String {
        let expanded = Self.expand(cwd)
        var args = ["diff", "--no-color"]
        if staged { args.append("--cached") }
        args.append("--")
        args.append(path)
        let (out, _, _) = await Self.run(executable: "git", args: args, cwd: expanded)
        return out
    }

    // MARK: - Stage / unstage

    func stage(taskId: String, cwd: String, paths: [String]) async {
        guard !paths.isEmpty else { return }
        let expanded = Self.expand(cwd)
        _ = await Self.run(executable: "git", args: ["add", "--"] + paths, cwd: expanded)
        await refresh(taskId: taskId, cwd: cwd)
    }

    func unstage(taskId: String, cwd: String, paths: [String]) async {
        guard !paths.isEmpty else { return }
        let expanded = Self.expand(cwd)
        _ = await Self.run(executable: "git", args: ["reset", "HEAD", "--"] + paths, cwd: expanded)
        await refresh(taskId: taskId, cwd: cwd)
    }

    func stageAll(taskId: String, cwd: String) async {
        let expanded = Self.expand(cwd)
        _ = await Self.run(executable: "git", args: ["add", "-A"], cwd: expanded)
        await refresh(taskId: taskId, cwd: cwd)
    }

    func unstageAll(taskId: String, cwd: String) async {
        let expanded = Self.expand(cwd)
        _ = await Self.run(executable: "git", args: ["reset", "HEAD"], cwd: expanded)
        await refresh(taskId: taskId, cwd: cwd)
    }

    // MARK: - Commit

    func commit(taskId: String, cwd: String, message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastOpResult[taskId] = GitOpResult(success: false, message: "Commit message is empty.")
            return
        }
        let expanded = Self.expand(cwd)
        let (out, err, code) = await Self.run(
            executable: "git",
            args: ["commit", "-m", trimmed],
            cwd: expanded
        )
        if code == 0 {
            let first = (out.split(separator: "\n").first.map(String.init) ?? "Committed")
            lastOpResult[taskId] = GitOpResult(success: true, message: first)
        } else {
            lastOpResult[taskId] = GitOpResult(success: false,
                                               message: err.isEmpty ? out : err)
        }
        await refresh(taskId: taskId, cwd: cwd)
    }

    // MARK: - Push / Pull

    func push(taskId: String, cwd: String) async {
        await runRemoteOp(taskId: taskId, cwd: cwd,
                          args: ["push"],
                          successPrefix: "Pushed")
    }

    func pull(taskId: String, cwd: String) async {
        await runRemoteOp(taskId: taskId, cwd: cwd,
                          args: ["pull", "--ff-only"],
                          successPrefix: "Pulled")
    }

    private func runRemoteOp(taskId: String,
                             cwd: String,
                             args: [String],
                             successPrefix: String) async {
        inFlight.insert(taskId)
        defer { inFlight.remove(taskId) }
        let expanded = Self.expand(cwd)
        let (out, err, code) = await Self.run(executable: "git", args: args, cwd: expanded)
        if code == 0 {
            let msg = err.isEmpty ? out : err
            let firstLine = msg.split(separator: "\n").first.map(String.init) ?? successPrefix
            lastOpResult[taskId] = GitOpResult(success: true, message: firstLine)
        } else {
            let msg = err.isEmpty ? out : err
            let firstLine = msg.split(separator: "\n").first.map(String.init) ?? "Failed"
            lastOpResult[taskId] = GitOpResult(success: false, message: firstLine)
        }
        await refresh(taskId: taskId, cwd: cwd)
    }

    func clearOpResult(taskId: String) {
        lastOpResult.removeValue(forKey: taskId)
    }

    // MARK: - Lifecycle

    func clear(taskId: String) {
        states.removeValue(forKey: taskId)
        lastOpResult.removeValue(forKey: taskId)
        inFlight.remove(taskId)
    }

    // MARK: - Helpers

    /// `~` / `~/foo` → `/Users/.../foo`. Heart's other services do this same
    /// expansion themselves; centralizing it here avoids duplicating the
    /// NSString cast everywhere.
    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Resolves the absolute path of the `git` binary once per process. Without
    /// this we'd rely on `/usr/bin/env git`, which works but spawns one extra
    /// process per call — `Process` lets us skip the wrapper if we know the
    /// path. Falls back to `/usr/bin/env` on PATH resolution failure.
    ///
    /// `nonisolated` because the enclosing class is `@MainActor` but this
    /// constant is read from the background `DispatchQueue` we shell out on.
    nonisolated private static let gitExecutable: URL = {
        // Common locations on macOS, in priority order.
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }()

    /// Returns (stdout, stderr, exit code). Captures both streams fully —
    /// callers can ignore whichever they don't need.
    fileprivate static func run(executable: String,
                                args: [String],
                                cwd: String) async -> (String, String, Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                if gitExecutable.lastPathComponent == "env" {
                    process.executableURL = gitExecutable
                    process.arguments = [executable] + args
                } else {
                    process.executableURL = gitExecutable
                    process.arguments = args
                }
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // Give git a sane env — strip GIT_DIR / GIT_WORK_TREE that
                // might be leaking from a parent shell session.
                var env = ProcessInfo.processInfo.environment
                env.removeValue(forKey: "GIT_DIR")
                env.removeValue(forKey: "GIT_WORK_TREE")
                env.removeValue(forKey: "GIT_INDEX_FILE")
                process.environment = env

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("", "Failed to launch git: \(error.localizedDescription)", -1))
                    return
                }

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: (out, err, process.terminationStatus))
            }
        }
    }

    fileprivate static func runStatus(at cwd: String) async -> GitRepoState {
        let (out, err, code) = await run(
            executable: "git",
            args: ["status", "--porcelain=v1", "-z", "-b", "--untracked-files=all"],
            cwd: cwd
        )
        if code != 0 {
            return GitRepoState(branch: "—",
                                upstream: nil,
                                ahead: 0,
                                behind: 0,
                                files: [],
                                lastRefreshError: err.isEmpty ? "Not a git repository." : err)
        }
        return parseStatus(out)
    }

    /// Parses `git status --porcelain=v1 -z -b --untracked-files=all` output.
    /// First NUL-terminated record is the branch line ("## main...origin/main
    /// [ahead 1, behind 2]"). Subsequent records are "XY path" with X = staged
    /// state, Y = unstaged state. Renames produce two records (target then
    /// source); we only show the target.
    static func parseStatus(_ raw: String) -> GitRepoState {
        let records = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var branch = "—"
        var upstream: String?
        var ahead = 0
        var behind = 0
        var files: [GitFile] = []

        var skipNext = false
        for (idx, record) in records.enumerated() {
            if skipNext {
                skipNext = false
                continue
            }
            if idx == 0 && record.hasPrefix("## ") {
                let body = String(record.dropFirst(3))
                // "HEAD (no branch)" / "main" / "main...origin/main [ahead 1, behind 2]"
                if body.hasPrefix("HEAD ") {
                    branch = "HEAD"
                } else if let range = body.range(of: "...") {
                    branch = String(body[..<range.lowerBound])
                    let rest = String(body[range.upperBound...])
                    if let bracket = rest.range(of: " [") {
                        upstream = String(rest[..<bracket.lowerBound])
                        let tracking = rest[bracket.upperBound...].dropLast()
                        // " ahead 1, behind 2"
                        for part in tracking.split(separator: ",") {
                            let trimmed = part.trimmingCharacters(in: .whitespaces)
                            if trimmed.hasPrefix("ahead "), let n = Int(trimmed.dropFirst(6)) {
                                ahead = n
                            } else if trimmed.hasPrefix("behind "), let n = Int(trimmed.dropFirst(7)) {
                                behind = n
                            }
                        }
                    } else {
                        upstream = rest
                    }
                } else {
                    branch = body
                }
                continue
            }

            guard record.count >= 3 else { continue }
            let chars = Array(record)
            let stagedChar = chars[0]
            let unstagedChar = chars[1]
            // chars[2] is a space separator
            let path = String(chars.dropFirst(3))

            let staged = GitChange.parse(stagedChar)
            let unstaged = GitChange.parse(unstagedChar)
            let untracked = (stagedChar == "?" && unstagedChar == "?")

            // Rename: next record is the source path — consume + ignore.
            if staged == .renamed || unstaged == .renamed {
                skipNext = true
            }

            files.append(GitFile(path: path,
                                 staged: staged,
                                 unstaged: unstaged,
                                 isUntracked: untracked))
        }

        return GitRepoState(branch: branch,
                            upstream: upstream,
                            ahead: ahead,
                            behind: behind,
                            files: files,
                            lastRefreshError: nil)
    }
}

// MARK: - Models

struct GitRepoState: Equatable {
    var branch: String
    var upstream: String?
    var ahead: Int
    var behind: Int
    var files: [GitFile]
    var lastRefreshError: String?

    var stagedCount: Int { files.filter(\.isStaged).count }
    var unstagedCount: Int { files.filter(\.isUnstaged).count }
    var totalChangedCount: Int { files.count }
}

struct GitFile: Identifiable, Equatable, Hashable {
    var path: String
    var staged: GitChange
    var unstaged: GitChange
    var isUntracked: Bool

    var id: String { path }
    var isStaged: Bool { staged != .none && !isUntracked }
    var isUnstaged: Bool { unstaged != .none || isUntracked }

    /// One-letter code for the sidebar pill. Staged takes precedence over
    /// unstaged when both exist on the same file (rare but possible).
    var statusLabel: String {
        if isUntracked { return "?" }
        if staged != .none { return staged.shortLabel }
        return unstaged.shortLabel
    }
}

enum GitChange: String, Equatable {
    case none, added, modified, deleted, renamed, copied, typeChanged, updated

    static func parse(_ c: Character) -> GitChange {
        switch c {
        case "A": return .added
        case "M": return .modified
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .updated
        case "?": return .added
        case " ": return .none
        default:  return .none
        }
    }

    var shortLabel: String {
        switch self {
        case .none:        return " "
        case .added:       return "A"
        case .modified:    return "M"
        case .deleted:     return "D"
        case .renamed:     return "R"
        case .copied:      return "C"
        case .typeChanged: return "T"
        case .updated:     return "U"
        }
    }
}

struct GitOpResult: Identifiable, Equatable {
    let id = UUID()
    let success: Bool
    let message: String
}
