import SwiftUI
import AppKit

/// Bridge that lets `AppDelegate` (which receives Finder/dock JSON drops) push
/// URLs into the already-running ContentView instead of letting SwiftUI's
/// WindowGroup spawn a second, blank window.
final class ContentRouter: ObservableObject {
    @Published var pendingImportURLs: [URL] = []
}

/// Posted with `object: Int` (1..9) when the user hits ⌘+digit. ContentView
/// listens for these and routes them either to a project switch (when the
/// selected task isn't a Claude shortcut) or to a Claude session switch
/// (when the active detail is a Claude row). Going through Notification
/// instead of binding lets the menu items live in `HeartApp.commands` while
/// the handler stays inside the SwiftUI view tree.
extension Notification.Name {
    static let heartSelectSlot = Notification.Name("Heart.SelectSlot")
    /// ⌘T — open a new terminal/session in the current detail context.
    /// (Claude shortcut → addSession; other tasks → spawn a fresh terminal
    /// task at the current task's cwd.)
    static let heartNewTerminal = Notification.Name("Heart.NewTerminal")
    /// ⌘W — close the active terminal/session. Scoped to Claude sessions
    /// and ephemeral terminal-shortcut tasks; refuses to act on
    /// user-configured tasks so the shortcut can't accidentally nuke
    /// somebody's heart.json entry.
    static let heartCloseTerminal = Notification.Name("Heart.CloseTerminal")
}

@main
struct HeartApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = TaskStore()
    @StateObject private var processManager = ProcessManager()
    @StateObject private var browserManager = BrowserManager()
    @StateObject private var gitManager = GitManager()
    @StateObject private var router = ContentRouter()

    var body: some Scene {
        // Title text is intentionally empty — the project tab bar at the top of
        // ContentView already shows the active project's name, so the system
        // title would just duplicate it (and looked centered + cluttered).
        WindowGroup("") {
            ContentView(store: store,
                        processManager: processManager,
                        browserManager: browserManager,
                        gitManager: gitManager,
                        router: router)
                .frame(minWidth: 900, minHeight: 560)
                .navigationTitle("")
                .toolbarBackground(.visible, for: .windowToolbar)
                .onAppear {
                    appDelegate.processManager = processManager
                    appDelegate.router = router
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // ⌘1..⌘9 — context-sensitive slot switcher. The actual destination
            // (project tab vs. Claude session) is decided in ContentView by
            // peeking at the current selection. Items are exposed in the menu
            // bar (Window → Go to slot N) so the shortcuts are discoverable.
            CommandMenu("Go") {
                ForEach(1..<10) { n in
                    Button("Slot \(n)") {
                        NotificationCenter.default.post(name: .heartSelectSlot,
                                                        object: n)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")),
                                      modifiers: .command)
                }
            }
            // ⌘T / ⌘W — terminal lifecycle, also handled by ContentView.
            // Lives in a Terminal menu so the shortcuts are discoverable
            // and so other Cocoa-default ⌘T (font panel) doesn't shadow ours.
            CommandMenu("Terminal") {
                Button("New Terminal / Session") {
                    NotificationCenter.default.post(name: .heartNewTerminal, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("Close Active Terminal / Session") {
                    NotificationCenter.default.post(name: .heartCloseTerminal, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var processManager: ProcessManager?
    weak var router: ContentRouter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force regular UI-app activation explicitly so that running the
        // executable directly (`swift run Heart`) brings the window to the
        // foreground. In a packaged .app bundle the Info.plist already gets
        // us this for free, so the calls are harmless duplicates there.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Silent update check ~5s after launch so it doesn't fight the UI
        // for the first frames. UpdateChecker self-throttles to once per
        // 24h, so this is cheap to call every launch.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await UpdateChecker.shared.checkNow(userInitiated: false)
        }
    }

    /// Finder/dock drops, `open` command, and "Open With Heart" all funnel
    /// through here. Forward the URLs to the existing window's ContentView
    /// instead of letting WindowGroup auto-open a second window for the file.
    func application(_ application: NSApplication, open urls: [URL]) {
        router?.pendingImportURLs.append(contentsOf: urls)
        // Bring the existing window to front so the user sees the import flow.
        if let win = NSApp.windows.first(where: { $0.contentViewController != nil }) {
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Clicking the dock icon when the app is running but the window is hidden
    /// should reuse the existing window, not spawn a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let win = NSApp.windows.first { win.makeKeyAndOrderFront(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        processManager?.terminateAllSync()
    }
}
