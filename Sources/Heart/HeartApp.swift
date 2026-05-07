import SwiftUI
import AppKit

@main
struct HeartApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = TaskStore()
    @StateObject private var processManager = ProcessManager()

    var body: some Scene {
        WindowGroup("Heart") {
            ContentView(store: store, processManager: processManager)
                .frame(minWidth: 900, minHeight: 560)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        processManager?.terminateAllSync()
    }
}
