import SwiftUI
import AppKit

@main
struct HeartApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = TaskStore()
    @StateObject private var processManager = ProcessManager()
    @StateObject private var browserManager = BrowserManager()

    var body: some Scene {
        // Title text is intentionally empty — the project tab bar at the top of
        // ContentView already shows the active project's name, so the system
        // title would just duplicate it (and looked centered + cluttered).
        WindowGroup("") {
            ContentView(store: store,
                        processManager: processManager,
                        browserManager: browserManager)
                .frame(minWidth: 900, minHeight: 560)
                .navigationTitle("")
                .toolbarBackground(.visible, for: .windowToolbar)
                .onAppear {
                    appDelegate.processManager = processManager
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var processManager: ProcessManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force regular UI-app activation explicitly so that running the
        // executable directly (`swift run Heart`) brings the window to the
        // foreground. In a packaged .app bundle the Info.plist already gets
        // us this for free, so the calls are harmless duplicates there.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        processManager?.terminateAllSync()
    }
}
