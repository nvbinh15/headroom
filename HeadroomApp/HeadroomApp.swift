import SwiftUI
import AppKit

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI requires a Scene. We don't actually use it — the AppDelegate
        // owns the menu-bar item and a hand-rolled NSWindow for Settings,
        // because the SwiftUI `Settings { … }` scene is unreliable in
        // LSUIElement (menu-bar-only) apps.
        Settings { EmptyView() }
    }
}
