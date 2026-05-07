import SwiftUI
import AppKit

struct OutputView: NSViewRepresentable {
    let text: String
    var isInteractive: Bool = false
    var onInput: ((Data) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        let textView = TerminalTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
        textView.textColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        textView.insertionPointColor = NSColor.systemGreen
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0,
                                                        height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TerminalTextView else { return }
        textView.onInput = onInput
        textView.isInteractive = isInteractive

        if textView.string != text {
            let wasAtBottom = isScrolledToBottom(scrollView)
            textView.string = text
            let end = (text as NSString).length
            textView.selectedRange = NSRange(location: end, length: 0)
            if wasAtBottom {
                DispatchQueue.main.async {
                    textView.scrollToEndOfDocument(nil)
                }
            }
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let visibleRect = scrollView.contentView.documentVisibleRect
        let bottom = documentView.frame.height - visibleRect.height
        return visibleRect.origin.y >= bottom - 40
    }
}

final class TerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?
    var isInteractive: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isInteractive, let onInput else {
            // No process to forward to — only let Cmd-shortcuts (copy/paste/select-all) through.
            if event.modifierFlags.contains(.command) {
                super.keyDown(with: event)
            }
            return
        }

        // Cmd-shortcuts (copy/paste/select-all/find) — let macOS handle them.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        // Ctrl combos (Ctrl+C, Ctrl+D, Ctrl+L, …)
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            let scalar = chars.unicodeScalars.first!.value
            if scalar >= 0x40 && scalar <= 0x7E {
                onInput(Data([UInt8(scalar & 0x1F)]))
                return
            }
        }

        switch event.keyCode {
        case 36, 76: onInput(Data([0x0D])); return       // Return / Enter
        case 51:    onInput(Data([0x7F])); return         // Backspace
        case 53:    onInput(Data([0x1B])); return         // Escape
        case 48:    onInput(Data([0x09])); return         // Tab
        case 123:   onInput(Data([0x1B, 0x5B, 0x44])); return // ←
        case 124:   onInput(Data([0x1B, 0x5B, 0x43])); return // →
        case 125:   onInput(Data([0x1B, 0x5B, 0x42])); return // ↓
        case 126:   onInput(Data([0x1B, 0x5B, 0x41])); return // ↑
        default:    break
        }

        if let chars = event.characters, !chars.isEmpty,
           let data = chars.data(using: .utf8) {
            onInput(data)
        }
        // Crucially do NOT call super: prevents NSTextView from inserting the typed
        // character locally — PTY echo will render it back through the output stream.
    }

    // Block paste from inserting locally; forward to stdin instead.
    override func paste(_ sender: Any?) {
        guard isInteractive, let onInput else {
            super.paste(sender)
            return
        }
        if let str = NSPasteboard.general.string(forType: .string),
           let data = str.data(using: .utf8) {
            onInput(data)
        }
    }
}
