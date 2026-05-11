import SwiftUI
import AppKit
import SwiftTerm

/// Hosts a `LocalProcessTerminalView` (owned by `ProcessManager`, one per task)
/// inside SwiftUI. Mount happens **once** per container — see makeNSView —
/// because shuffling the same terminalView between containers via
/// `removeFromSuperview` / `addSubview` on every selection change occasionally
/// blanked the visible buffer on macOS (the buffer is still there, but the
/// view doesn't redraw it).
///
/// Callers ensure container identity is fresh-per-task by tagging the parent
/// view with `.id(task.id)` so SwiftUI rebuilds the NSViewRepresentable
/// (and re-runs makeNSView with a brand-new container) when the user switches
/// tasks. The same terminalView instance can keep being passed in — moving it
/// between containers in makeNSView is a single atomic operation, and the
/// pending `requestRefresh` redraws the existing buffer.
struct OutputView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = ContainerView()
        container.autoresizingMask = [.width, .height]

        // Detach from any previous parent (different task's container) and mount.
        terminalView.removeFromSuperview()
        terminalView.frame = container.bounds
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)

        // Force the terminal to redraw its current buffer once the view is in
        // the window — without this, switching tasks sometimes shows a stale
        // / empty canvas even though the SwiftTerm buffer still has the output.
        DispatchQueue.main.async { [weak terminalView] in
            guard let view = terminalView, let window = view.window else { return }
            window.makeFirstResponder(view)
            view.needsDisplay = true
            view.getTerminal().refresh(startRow: 0, endRow: view.getTerminal().rows)
        }

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // No-op: container identity is fresh per task (via `.id(task.id)`
        // higher up). The mount in makeNSView is the only place we touch the
        // terminalView's view tree.
    }
}

/// Empty NSView subclass — exists only to give the container a stable type
/// for debugging breakpoints if mount issues resurface.
private final class ContainerView: NSView {}
