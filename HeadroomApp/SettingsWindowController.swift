import AppKit
import SwiftUI

/// Hand-rolled Settings window. We can't rely on SwiftUI's `Settings` scene
/// in `LSUIElement` apps — `NSApp.sendAction("showSettingsWindow:")` has no
/// responder when there's no Dock icon, so the menu item silently does
/// nothing. Owning an NSWindow directly is bulletproof.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let refreshController: RefreshController

    init(refreshController: RefreshController) {
        self.refreshController = refreshController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Headroom — Settings"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("HeadroomSettingsWindow")

        super.init(window: window)
        window.delegate = self

        // Frosted-glass underlay for the whole window. Matches the widget's
        // material aesthetic and lets desktop content blur through.
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.translatesAutoresizingMaskIntoConstraints = false

        let host = NSHostingView(
            rootView: SettingsView().environmentObject(refreshController)
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])

        window.contentView = glass
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func show() {
        // Bring the app forward even though it has no Dock icon, then make
        // the window key & ordered front.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
