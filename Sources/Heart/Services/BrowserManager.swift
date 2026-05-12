import Foundation
import Combine
import WebKit

/// Per-task BrowserModel cache. Without this, switching to another task and back
/// re-mounts BrowserView, which destroys the `@StateObject` BrowserModel, throws
/// away the WKWebView, and reloads the page from scratch. The manager owns the
/// models so navigation history, scroll position, cookies (already persistent via
/// the shared `.default()` data store), localStorage, and granted media-capture
/// permissions all survive across selection changes.
final class BrowserManager: ObservableObject {
    private var models: [String: BrowserModel] = [:]

    /// Returns the cached model for this task, creating it on first use.
    /// `initialURL` is only used when the model is first created — subsequent
    /// calls with a different `initialURL` do NOT navigate the existing model
    /// (URL changes from the task config are handled separately by BrowserView's
    /// onChange observer).
    func model(for taskId: String, initialURL: String) -> BrowserModel {
        if let existing = models[taskId] {
            return existing
        }
        let model = BrowserModel(initialURL: initialURL)
        models[taskId] = model
        return model
    }

    /// Drop the cached model for a task — used when the task is deleted so we
    /// don't hold onto its WKWebView forever.
    func clear(taskId: String) {
        models.removeValue(forKey: taskId)
    }

    /// Drop every cached model (e.g. on app quit). Releasing WKWebView instances
    /// stops any background page activity (timers, websockets, video playback).
    func clearAll() {
        models.removeAll()
    }
}
