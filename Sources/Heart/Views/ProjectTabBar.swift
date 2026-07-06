import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Top-of-window strip listing every project (top-level folder) as a tab.
/// Selection drives which project's tasks render in the sidebar.
struct ProjectTabBar: View {
    let projects: [String]
    @Binding var selection: String?
    /// (running, total) by project name.
    let runningCounts: [String: (Int, Int)]
    /// Number of Claude sessions waiting on the user, by project name. >0 lights
    /// up a red dot on the pill so the user can spot which project needs them.
    let waitingCounts: [String: Int]
    /// `nil` source = empty/manual project; otherwise the path of the linked JSON.
    let sources: [String: String]

    let onSelect: (String) -> Void
    let onPickFile: () -> Void
    let onCreateEmpty: () -> Void
    let onShowFormatHelp: () -> Void
    /// Called when a JSON file is dropped onto the tab bar (not onto a specific tab).
    /// Should import as a new project.
    let onDropNewProject: ([URL]) -> Void
    /// Called when a JSON file is dropped directly onto an existing project pill.
    /// Should replace that project's tasks (with the usual confirm prompt).
    let onDropOntoProject: (String, [URL]) -> Void
    let onReorder: ([String]) -> Void

    let onRename: (String) -> Void
    let onSave: (String) -> Void
    let onSaveAs: (String) -> Void
    let onUnlinkSource: (String) -> Void
    let onExport: (String) -> Void
    let onStartAll: (String) -> Void
    let onStopAll: (String) -> Void
    let onRestartAll: (String) -> Void
    let onDelete: (String) -> Void

    @State private var dropTargeted: Bool = false
    /// Tab the user just clicked — used to flag the pill as "pending" so the
    /// UI feels responsive while SwiftUI rebuilds the (heavy) sidebar +
    /// detail tree for the new selection. Cleared as soon as `selection`
    /// actually moves to it.
    @State private var pendingSelection: String?
    /// Drives a thin progress shimmer at the bottom of the bar while the
    /// switch is in flight. Same lifetime as `pendingSelection`.
    @State private var isSwitching: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(projects, id: \.self) { project in
                            pill(for: project)
                                .id(project)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: selection) { newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            Divider().frame(height: 22)

            addButton
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                Color(NSColor.windowBackgroundColor)
                if dropTargeted {
                    Color.accentColor.opacity(0.08)
                }
            }
        )
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 0.5)
                if isSwitching {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0),
                                 Color.accentColor,
                                 Color.accentColor.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 2)
                    .transition(.opacity)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDropNewProject(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: selection) { _ in
            // Selection landed — drop the pending flag so the pill reverts to
            // its real selected/idle stylingt. The brief "isSwitching" pulse
            // lingers ~120ms past the change so the bar animation finishes.
            pendingSelection = nil
            withAnimation(.easeOut(duration: 0.18)) { isSwitching = false }
        }
    }

    // MARK: - Pill

    @ViewBuilder
    private func pill(for project: String) -> some View {
        let isActive = (selection == project)
        let isPending = (pendingSelection == project && !isActive)
        // Pending styling sits halfway between idle and active so the user
        // can see the click registered even before SwiftUI finishes the
        // sidebar rebuild — without faking a "you're already there" state.
        let displayActive = isActive || isPending
        let counts = runningCounts[project] ?? (0, 0)
        let hasSource = sources[project] != nil

        HStack(spacing: 6) {
            if isPending {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: hasSource ? "doc.text.fill" : "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(displayActive ? Color.accentColor : .secondary)
            }
            Text(project)
                .font(.system(size: 12, weight: displayActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(displayActive ? Color.primary : Color.secondary)
            badge(running: counts.0, total: counts.1)
            let waiting = waitingCounts[project] ?? 0
            if waiting > 0 {
                Text(verbatim: "\(waiting)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .help("\(waiting) Claude session aksiyon bekliyor")
            }
        }
        .frame(maxWidth: 180)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? Color.accentColor.opacity(0.18)
                      : (isPending
                         ? Color.accentColor.opacity(0.10)
                         : Color.secondary.opacity(0.06)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(displayActive
                        ? Color.accentColor.opacity(isPending ? 0.35 : 0.55)
                        : Color.secondary.opacity(0.18),
                        lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .help(project)
        .onTapGesture {
            guard selection != project else { return }
            pendingSelection = project
            withAnimation(.easeIn(duration: 0.08)) { isSwitching = true }
            onSelect(project)
        }
        .contextMenu { contextMenu(for: project) }
        .draggable(project) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").font(.system(size: 10))
                Text(project).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.25))
            )
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first, dragged != project else { return false }
            // Defer one runloop tick so SwiftUI's drag-end animation finishes
            // before we rebuild the array — otherwise the tab visibly hitches
            // for a frame as the source view is destroyed mid-animation.
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.22)) {
                    reorder(dragged: dragged, before: project)
                }
            }
            return true
        }
        // URL drop on the pill = replace that project's tasks. Without this,
        // dropping a JSON onto a pill fell through to the system, which opened
        // the file in a brand-new Heart window.
        .dropDestination(for: URL.self) { urls, _ in
            onDropOntoProject(project, urls)
            return true
        }
    }

    @ViewBuilder
    private func badge(running: Int, total: Int) -> some View {
        if total == 0 {
            EmptyView()
        } else {
            Text(verbatim: "(\(running)/\(total))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(running > 0 ? Color.green : Color.secondary.opacity(0.6))
        }
    }

    @ViewBuilder
    private func contextMenu(for project: String) -> some View {
        Button { onRename(project) } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Divider()
        if let path = sources[project] {
            Button { onSave(project) } label: {
                Label("Save to \((path as NSString).lastPathComponent)",
                      systemImage: "square.and.arrow.down")
            }
        }
        Button { onSaveAs(project) } label: {
            Label("Save as…", systemImage: "square.and.arrow.down.on.square")
        }
        Button { onExport(project) } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        if sources[project] != nil {
            Button { onUnlinkSource(project) } label: {
                Label("Unlink source", systemImage: "link.badge.plus")
            }
        }
        Divider()
        Button { onStartAll(project) } label: {
            Label("Start all", systemImage: "play.fill")
        }
        Button { onStopAll(project) } label: {
            Label("Stop all", systemImage: "stop.fill")
        }
        Button { onRestartAll(project) } label: {
            Label("Restart all", systemImage: "arrow.clockwise")
        }
        Divider()
        Button(role: .destructive) { onDelete(project) } label: {
            Label("Delete project", systemImage: "trash")
        }
    }

    // MARK: - Add button

    @ViewBuilder
    private var addButton: some View {
        Menu {
            Button { onShowFormatHelp() } label: {
                Label("Generate with Claude…", systemImage: "sparkles")
            }
            Divider()
            Button { onPickFile() } label: {
                Label("Import from JSON…", systemImage: "square.and.arrow.down")
            }
            Button { onCreateEmpty() } label: {
                Label("Empty project", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Add Project")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.4),
                            style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a project (from JSON file or empty)")
    }

    // MARK: - Reorder

    private func reorder(dragged: String, before target: String) {
        guard let from = projects.firstIndex(of: dragged),
              let to = projects.firstIndex(of: target) else { return }
        var next = projects
        next.remove(at: from)
        let insertAt = (from < to) ? to - 1 : to
        next.insert(dragged, at: insertAt)
        onReorder(next)
    }
}
