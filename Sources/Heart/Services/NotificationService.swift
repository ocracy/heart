import Foundation
import AppKit

/// System notification + sound for "a Claude session needs you".
///
/// Heart ships unsigned / ad-hoc signed, where `UNUserNotificationCenter` is
/// unreliable (needs a provisioned bundle and asks for permission). `osascript`
/// `display notification … sound name …` needs no entitlement and delivers both
/// the banner and the sound in a single fire-and-forget call.
enum NotificationService {
    static func notifyWaiting(name: String, project: String) {
        let body = name.isEmpty ? "Claude bir aksiyon bekliyor" : "\(name) bekliyor"
        var script = "display notification \(quote(body)) with title \(quote("Heart"))"
        if !project.isEmpty {
            script += " subtitle \(quote(project))"
        }
        script += " sound name \"Glass\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        // Fire-and-forget: the launched osascript process outlives this Process
        // object, so we don't wait on it.
        try? proc.run()
    }

    /// Quote a string as an AppleScript string literal.
    private static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
