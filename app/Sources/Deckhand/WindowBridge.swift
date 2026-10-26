// WindowBridge.swift — reopening a closed SwiftUI window.
//
// A WindowGroup releases its window when it is closed, so `makeKeyAndOrderFront` has nothing to act on.
// ContentView lends us SwiftUI's `openWindow` action, and everything that means "show me the app"
// (Dock click, `open -a Deckhand`, the menu-bar item) goes through here.
import AppKit
import SwiftUI

@MainActor
final class WindowBridge {
    static let shared = WindowBridge()

    /// Set from ContentView, where the environment action is available.
    var openMainWindow: (() -> Void)?

    func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // no live window: ask SwiftUI to build one from the "main" scene
        if let openMainWindow {
            openMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            }
            Log.write("reopened the main window")
        } else {
            Log.write("reopen requested before the view was ready")
        }
    }
}
