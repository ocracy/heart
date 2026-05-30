import SwiftUI
import AppKit
import SwiftTerm

/// Hosts a `LocalProcessTerminalView` (owned by `ProcessManager`, one per task)
/// inside SwiftUI. The container is mounted **once** per regularDetail and the
/// embedded terminal view is swapped in/out when the user changes tasks — so
/// SwiftTerm's internal scroll position survives selection changes (re-mounting
/// the whole representable on every switch was resetting it to the bottom).
///
/// Callers do NOT tag the parent view with `.id(task.id)` — the swap-on-update
/// here is what keeps each task's buffer visible.
struct OutputView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.autoresizingMask = [.width, .height]
        container.attach(terminalView)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.attach(terminalView)
    }
}

/// Owns one terminal view at a time. `attach` is idempotent: passing the same
/// terminal twice in a row does nothing, so SwiftUI's frequent updateNSView
/// calls don't churn the view tree.
final class TerminalContainerView: NSView {
    private weak var currentTerminal: LocalProcessTerminalView?

    func attach(_ tv: LocalProcessTerminalView) {
        if currentTerminal === tv { return }
        // Remove the previously-attached terminal (if any) and the new one's
        // previous parent (a different TerminalContainerView from another
        // task swap) so we don't end up with the same NSView in two hierarchies.
        currentTerminal?.removeFromSuperview()
        tv.removeFromSuperview()
        tv.frame = bounds
        tv.autoresizingMask = [.width, .height]
        addSubview(tv)
        currentTerminal = tv

        // Force a redraw once the view is on-screen — SwiftTerm sometimes
        // shows a stale / empty canvas right after a re-attach even though
        // the buffer is still populated. Doing this async lets the view
        // settle into its window first. We also re-trigger `setFrameSize` to
        // guarantee SwiftTerm's processSizeChange runs (which calls
        // `terminal.resize(cols:rows:)` AND TIOCSWINSZ on the child PTY).
        // Without this, attach swaps between containers can leave the child
        // process thinking the terminal is still its old (sometimes 0×0)
        // size — the symptom is Claude Code etc. drawing each character on
        // its own line, as if cols=1.
        DispatchQueue.main.async { [weak tv, weak self] in
            guard let view = tv, let self = self, let window = view.window else { return }
            let target = self.bounds.size
            if target.width > 0 && target.height > 0 {
                // Setting to .zero then back forces processSizeChange to fire
                // even when the size hasn't numerically changed since attach.
                view.setFrameSize(target)
            }
            window.makeFirstResponder(view)
            view.needsDisplay = true
            view.getTerminal().refresh(startRow: 0, endRow: view.getTerminal().rows)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Container resized (window drag, split-view drag, sidebar toggle…).
        // Forward the new size to SwiftTerm so it re-runs processSizeChange
        // even if autoresizingMask alone fails to trigger it (which it can on
        // first show, before the view tree is in a window). This is the path
        // that keeps `claude` from getting stuck with stale cols/rows after
        // the user changes layout.
        if let tv = currentTerminal, newSize.width > 0, newSize.height > 0 {
            tv.setFrameSize(newSize)
        }
    }
}
