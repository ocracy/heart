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
    /// Debounce timer for live window/sidebar drags. Without it, SwiftTerm
    /// runs its `processSizeChange` (which mutates terminal state + calls
    /// TIOCSWINSZ on the child PTY) on every single mouse-move during a
    /// drag — that's where the "resize sometimes makes it worse" symptom
    /// in `claude` was coming from. Coalescing to the trailing edge gives
    /// SwiftTerm + the child process a single, clean resize event.
    private var resizeDebounce: DispatchWorkItem?

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
        // the buffer is still populated. We do TWO passes:
        //  • t=0  : settle size + focus + initial refresh
        //  • t=350ms : second refresh after Cocoa's layout cycle has run.
        // The double-tap matters because users reported that flipping
        // between tasks "sometimes" fixed the Claude render glitch — the
        // first refresh races SwiftUI's full layout pass, so a second one
        // after settle is what makes the recovery deterministic.
        DispatchQueue.main.async { [weak tv, weak self] in
            guard let view = tv, let self = self, let window = view.window else { return }
            let target = self.bounds.size
            if target.width > 0 && target.height > 0 {
                view.setFrameSize(target)
            }
            window.makeFirstResponder(view)
            view.needsDisplay = true
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak tv] in
            guard let view = tv, view.window != nil else { return }
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let tv = currentTerminal, newSize.width > 0, newSize.height > 0 else { return }

        // First pass: keep the NSView in sync with the container so the
        // canvas keeps tracking the drag in real time (otherwise it'd
        // appear frozen until the user lets go of the mouse).
        tv.setFrameSize(newSize)

        // Second pass: debounce a clean repaint to the trailing edge of
        // the drag. SwiftTerm's resize pipeline is heavy (it recomputes
        // cols/rows, calls TIOCSWINSZ, dispatches a sizeChanged event);
        // running it on every drag frame is what caused the "smeared
        // characters" mid-drag. 80ms after the last resize tick, the
        // user has stopped — that's when we run a single refresh.
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak tv] in
            guard let view = tv, view.window != nil else { return }
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
