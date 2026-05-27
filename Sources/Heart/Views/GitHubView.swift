import SwiftUI
import AppKit

/// GitHub Desktop-style detail pane for `kind: "github"` tasks.
///
/// Layout:
/// ┌────────────────────────────────────────────────────────────┐
/// │ top bar — branch · ↑↓ counts · Pull / Push / Refresh / toast│
/// ├──────────────────────────┬──────────────────────────────────┤
/// │ left list (changed files)│ right diff (file content)        │
/// │  - checkbox = stage state│  + green / - red / @@ purple    │
/// │  - status pill (M/A/D/?) │                                  │
/// │  - bulk stage / unstage  │                                  │
/// ├──────────────────────────┴──────────────────────────────────┤
/// │ commit bar — TextField + "Commit N"                         │
/// └─────────────────────────────────────────────────────────────┘
struct GitHubView: View {
    let task: DevTask
    @ObservedObject var gitManager: GitManager

    @State private var selectedFilePath: String?
    @State private var diffText: String = ""
    @State private var diffIsStaged: Bool = false
    @State private var commitMessage: String = ""
    @State private var toast: GitOpResult?
    @State private var toastDismissAt: Date?
    @State private var branchList: [String] = []
    @State private var showNewBranchSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                fileListColumn
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)
                diffColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            commitBar
        }
        .onAppear {
            Task {
                await gitManager.refresh(taskId: task.id, cwd: task.cwd)
                branchList = await gitManager.branches(cwd: task.cwd)
            }
        }
        .sheet(isPresented: $showNewBranchSheet) {
            NewBranchSheet(
                currentBranch: state?.branch ?? "—",
                hasDirtyChanges: (state?.totalChangedCount ?? 0) > 0,
                onCancel: { showNewBranchSheet = false },
                onCreate: { name, switchTo in
                    showNewBranchSheet = false
                    Task {
                        await gitManager.createBranch(taskId: task.id,
                                                       cwd: task.cwd,
                                                       name: name,
                                                       switchTo: switchTo)
                        branchList = await gitManager.branches(cwd: task.cwd)
                    }
                }
            )
        }
        .onChange(of: gitManager.lastOpResult[task.id]) { newValue in
            guard let result = newValue else { return }
            toast = result
            toastDismissAt = Date().addingTimeInterval(3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) {
                if let deadline = toastDismissAt, Date() >= deadline {
                    toast = nil
                    toastDismissAt = nil
                    gitManager.clearOpResult(taskId: task.id)
                }
            }
        }
        .onChange(of: selectedFilePath) { _ in
            Task { await loadDiff() }
        }
        .onChange(of: state?.files ?? []) { _ in
            // After every refresh, if our selection vanished from the list
            // (e.g. staged file was committed), drop it so the diff pane goes
            // back to the placeholder. Otherwise, reload its diff in case the
            // stage state flipped (staged ↔ unstaged shows different content).
            if let sel = selectedFilePath,
               !(state?.files.contains(where: { $0.path == sel }) ?? false) {
                selectedFilePath = nil
                diffText = ""
            } else if selectedFilePath != nil {
                Task { await loadDiff() }
            }
        }
    }

    private var state: GitRepoState? { gitManager.states[task.id] }
    private var inFlight: Bool { gitManager.inFlight.contains(task.id) }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                branchMenu
                if let upstream = state?.upstream {
                    Text("→ \(upstream)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let ahead = state?.ahead, ahead > 0 {
                    Text("↑\(ahead)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if let behind = state?.behind, behind > 0 {
                    Text("↓\(behind)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                if let err = state?.lastRefreshError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                opButton(
                    label: pullLabel,
                    systemImage: "arrow.down.circle.fill",
                    tint: .orange,
                    help: "git pull --ff-only"
                ) {
                    Task { await gitManager.pull(taskId: task.id, cwd: task.cwd) }
                }
                opButton(
                    label: pushLabel,
                    systemImage: "arrow.up.circle.fill",
                    tint: .green,
                    help: "git push"
                ) {
                    Task { await gitManager.push(taskId: task.id, cwd: task.cwd) }
                }
                opButton(
                    label: "Refresh",
                    systemImage: "arrow.clockwise",
                    tint: .secondary,
                    help: "Re-read git status"
                ) {
                    Task { await gitManager.refresh(taskId: task.id, cwd: task.cwd) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)

            if let toast {
                toastBanner(toast)
            }
        }
    }

    @ViewBuilder
    private var branchMenu: some View {
        let current = state?.branch ?? "—"
        Menu {
            Section("Switch branch") {
                ForEach(branchList, id: \.self) { name in
                    Button {
                        guard name != current else { return }
                        Task {
                            await gitManager.checkout(taskId: task.id,
                                                       cwd: task.cwd,
                                                       branch: name)
                            branchList = await gitManager.branches(cwd: task.cwd)
                        }
                    } label: {
                        if name == current {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                if branchList.isEmpty {
                    Text("No local branches")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Button {
                showNewBranchSheet = true
            } label: {
                Label("New branch…", systemImage: "plus")
            }
            Button {
                Task { branchList = await gitManager.branches(cwd: task.cwd) }
            } label: {
                Label("Refresh branches", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.purple)
                Text(current)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.purple.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.purple.opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch branch or create a new one")
        .onAppear {
            Task { branchList = await gitManager.branches(cwd: task.cwd) }
        }
    }

    private var pushLabel: String {
        guard let n = state?.ahead, n > 0 else { return "Push" }
        return "Push \(n)"
    }
    private var pullLabel: String {
        guard let n = state?.behind, n > 0 else { return "Pull" }
        return "Pull \(n)"
    }

    @ViewBuilder
    private func opButton(label: String,
                          systemImage: String,
                          tint: Color,
                          help: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if inFlight {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(inFlight)
        .help(help)
    }

    @ViewBuilder
    private func toastBanner(_ result: GitOpResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.success ? .green : .red)
            Text(result.message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer()
            Button {
                toast = nil
                toastDismissAt = nil
                gitManager.clearOpResult(taskId: task.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(result.success ? Color.green.opacity(0.08) : Color.red.opacity(0.10))
    }

    // MARK: - File list

    private var fileListColumn: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                if let count = state?.totalChangedCount {
                    Text("(\(count))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("All ↑") {
                    Task { await gitManager.stageAll(taskId: task.id, cwd: task.cwd) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
                .help("Stage all changes")
                .disabled((state?.unstagedCount ?? 0) == 0)
                Button("All ↓") {
                    Task { await gitManager.unstageAll(taskId: task.id, cwd: task.cwd) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
                .help("Unstage all changes")
                .disabled((state?.stagedCount ?? 0) == 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.05))

            Divider()

            if let files = state?.files, !files.isEmpty {
                List(selection: $selectedFilePath) {
                    ForEach(files) { file in
                        fileRow(file)
                            .tag(file.path)
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 28))
                        .foregroundStyle(.green.opacity(0.7))
                    Text(state?.lastRefreshError != nil ? "Not a repository" : "No changes")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: GitFile) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    if file.isStaged {
                        await gitManager.unstage(taskId: task.id,
                                                  cwd: task.cwd,
                                                  paths: [file.path])
                    } else {
                        await gitManager.stage(taskId: task.id,
                                                cwd: task.cwd,
                                                paths: [file.path])
                    }
                }
            } label: {
                Image(systemName: file.isStaged
                      ? "checkmark.square.fill"
                      : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(file.isStaged ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            statusPill(for: file)

            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(file.isUntracked ? Color.secondary : Color.primary)
                .italic(file.isUntracked)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func statusPill(for file: GitFile) -> some View {
        let label = file.statusLabel
        let tint = statusTint(for: file)
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.15)))
    }

    private func statusTint(for file: GitFile) -> Color {
        if file.isUntracked { return .secondary }
        switch file.staged != .none ? file.staged : file.unstaged {
        case .added, .copied:   return .green
        case .modified, .updated, .typeChanged: return .blue
        case .deleted:          return .red
        case .renamed:          return .orange
        case .none:             return .secondary
        }
    }

    // MARK: - Diff

    private var diffColumn: some View {
        VStack(spacing: 0) {
            if let selected = selectedFilePath {
                HStack(spacing: 8) {
                    Text(selected)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if diffIsStaged {
                        Text("STAGED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.18)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.05))
                Divider()
                diffScrollView
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("Select a file to view the diff")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var diffScrollView: some View {
        ScrollView([.vertical, .horizontal]) {
            if diffText.isEmpty {
                Text("(no diff)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        diffLineView(line)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var diffLines: [Substring] {
        diffText.split(separator: "\n", omittingEmptySubsequences: false)
    }

    @ViewBuilder
    private func diffLineView(_ line: Substring) -> some View {
        let kind = diffLineKind(line)
        HStack(spacing: 0) {
            Text(String(line.isEmpty ? " " : line))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(kind.foreground)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.background)
    }

    private enum DiffLineKind {
        case added, removed, hunk, fileHeader, context
        var foreground: Color {
            switch self {
            case .added:      return .green
            case .removed:    return .red
            case .hunk:       return .purple
            case .fileHeader: return .secondary
            case .context:    return .primary
            }
        }
        var background: Color {
            switch self {
            case .added:      return Color.green.opacity(0.08)
            case .removed:    return Color.red.opacity(0.08)
            case .hunk:       return Color.purple.opacity(0.08)
            case .fileHeader: return Color.secondary.opacity(0.05)
            case .context:    return .clear
            }
        }
    }

    private func diffLineKind(_ line: Substring) -> DiffLineKind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return .fileHeader
        }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }

    private func loadDiff() async {
        guard let path = selectedFilePath,
              let files = state?.files,
              let file = files.first(where: { $0.path == path }) else {
            diffText = ""
            diffIsStaged = false
            return
        }
        // Prefer the unstaged diff (working tree vs index) when it exists,
        // since that's what the user is actively editing. If a file is staged
        // only, show the staged diff so the pane isn't empty.
        let preferStaged = !file.isUnstaged && file.isStaged
        diffIsStaged = preferStaged
        if file.isUntracked {
            // Untracked files have no diff; show the file contents prefixed
            // with "+" so it visually matches the additions style.
            let expanded = GitManager.expand(task.cwd)
            let url = URL(fileURLWithPath: expanded).appendingPathComponent(path)
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                diffText = text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "+\($0)" }
                    .joined(separator: "\n")
            } else {
                diffText = "(binary or unreadable)"
            }
            diffIsStaged = false
            return
        }
        diffText = await gitManager.diff(cwd: task.cwd, path: path, staged: preferStaged)
    }

    // MARK: - Commit bar

    private var commitBar: some View {
        HStack(spacing: 10) {
            TextField(commitPlaceholder, text: $commitMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(NSColor.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
                .onSubmit { performCommit() }

            Button(action: performCommit) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(commitButtonLabel)
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.03))
    }

    private var canCommit: Bool {
        !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (state?.stagedCount ?? 0) > 0
    }

    private var commitButtonLabel: String {
        let n = state?.stagedCount ?? 0
        return n > 0 ? "Commit \(n)" : "Commit"
    }

    private var commitPlaceholder: String {
        let n = state?.stagedCount ?? 0
        if n == 0 { return "Stage some files first…" }
        return "Commit message — describe what changed"
    }

    private func performCommit() {
        guard canCommit else { return }
        let msg = commitMessage
        commitMessage = ""
        Task {
            await gitManager.commit(taskId: task.id, cwd: task.cwd, message: msg)
        }
    }
}

// MARK: - NewBranchSheet

/// Compact sheet shown when the user picks "New branch…" from the branch menu.
/// If the working tree is dirty we ask whether the new branch should "take"
/// the uncommitted edits (checkout -b) or leave them on the current branch
/// (plain branch, no switch). Clean tree → just ask for a name + always check
/// out the new branch.
private struct NewBranchSheet: View {
    let currentBranch: String
    let hasDirtyChanges: Bool
    let onCancel: () -> Void
    let onCreate: (_ name: String, _ switchTo: Bool) -> Void

    @State private var name: String = ""
    /// true  = git checkout -b (move uncommitted edits to the new branch)
    /// false = git branch     (leave edits on the current branch)
    @State private var carryChanges: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("BRANCH NAME")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)
                    TextField("feature/new-thing", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
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
                        .onSubmit { commit() }
                    Text("Created from current HEAD on '\(currentBranch)'.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if hasDirtyChanges {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("UNCOMMITTED CHANGES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.6)
                        Text("Working tree has changes. What should happen to them?")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 8) {
                            choiceRow(
                                title: "Move to new branch",
                                detail: "Switch to the new branch and bring the uncommitted edits along (git checkout -b).",
                                isSelected: carryChanges,
                                onTap: { carryChanges = true }
                            )
                            choiceRow(
                                title: "Leave them on '\(currentBranch)'",
                                detail: "Create the new branch but stay here. The new branch is a clean pointer to the current HEAD; edits remain on '\(currentBranch)' (git branch).",
                                isSelected: !carryChanges,
                                onTap: { carryChanges = false }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            Divider()
            footer
        }
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.purple.opacity(0.15))
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.purple)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("New branch")
                    .font(.system(size: 16, weight: .semibold))
                Text("Create a branch from '\(currentBranch)'")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(action: commit) {
                Text("Create branch")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    @ViewBuilder
    private func choiceRow(title: String,
                           detail: String,
                           isSelected: Bool,
                           onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.purple : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.purple.opacity(0.07) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.purple.opacity(0.45) : Color.secondary.opacity(0.15),
                            lineWidth: 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Clean tree → switching to the new branch is always safe; treat
        // `carryChanges` as true so the user lands on the branch they just made.
        let shouldSwitch = hasDirtyChanges ? carryChanges : true
        onCreate(trimmed, shouldSwitch)
    }
}
