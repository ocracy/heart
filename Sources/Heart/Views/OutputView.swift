import SwiftUI
import AppKit
import SwiftTerm

/// Hosts a persistent `LocalProcessTerminalView` (owned by `ProcessManager`) inside SwiftUI.
/// The view itself is reused across selection changes so terminal state (cursor, scrollback,
/// modes set by TUIs like vim/htop) survives switching tasks.
struct OutputView: NSViewRepresentable {
    let terminalView: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Strip from any prior container (selection changed) before re-parenting.
        if terminalView.superview !== container {
            terminalView.removeFromSuperview()
            terminalView.frame = container.bounds
            terminalView.autoresizingMask = [.width, .height]
            container.addSubview(terminalView)
            // First-responder so keystrokes go to the terminal immediately.
            DispatchQueue.main.async {
                terminalView.window?.makeFirstResponder(terminalView)
            }
        }
    }
}
