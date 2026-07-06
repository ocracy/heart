import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` subclass used purely as a marker: when it hosts a
/// tmux-backed Claude session, `tmuxSessionName` is set, and ProcessManager's
/// scroll-wheel monitor redirects the wheel into that tmux session's copy-mode.
///
/// Why a monitor instead of overriding `scrollWheel`: SwiftTerm's `scrollWheel`
/// is `public` but not `open`, so it can't be overridden from here. And it's
/// needed at all because a Claude session's scrollback lives in *tmux's* history
/// (SwiftTerm only ever sees the single screen tmux paints), so SwiftTerm's own
/// wheel-scroll has nothing to move. Non-tmux terminals leave this nil and keep
/// SwiftTerm's normal local scrollback.
final class HeartTerminalView: LocalProcessTerminalView {
    var tmuxSessionName: String?
}
