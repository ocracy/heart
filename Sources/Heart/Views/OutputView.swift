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
        // settle into its window first.
        DispatchQueue.main.async { [weak tv] in
            guard let view = tv, let window = view.window else { return }
            window.makeFirstResponder(view)
            view.needsDisplay = true
            view.getTerminal().refresh(startRow: 0, endRow: view.getTerminal().rows)
        }
    }
}
