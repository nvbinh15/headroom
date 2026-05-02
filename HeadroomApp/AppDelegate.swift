import AppKit
import SwiftUI
import HeadroomKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let refreshController = RefreshController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var stateObserver: NSKeyValueObservation?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "…"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 240)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(refreshController)
        )

        // Re-render the status item label whenever state changes.
        Task { @MainActor in
            for await _ in refreshController.$state.values {
                self.updateStatusItemTitle()
            }
        }

        refreshController.start()
    }

    @MainActor
    private func updateStatusItemTitle() {
        let state = refreshController.state
        let claudePct = state.claude.fiveHour?.fraction
        let codexPct = state.codex.fiveHour?.fraction
        let str = NSMutableAttributedString()

        str.append(coloredSegment(
            label: "C",
            fraction: claudePct,
            weeklyFraction: state.claude.weekly?.fraction
        ))
        str.append(NSAttributedString(string: "  "))
        str.append(coloredSegment(
            label: "X",
            fraction: codexPct,
            weeklyFraction: state.codex.weekly?.fraction
        ))

        statusItem?.button?.attributedTitle = str
    }

    private func coloredSegment(label: String, fraction: Double?, weeklyFraction: Double?) -> NSAttributedString {
        let pctText: String
        if let f = fraction { pctText = "\(Int((f * 100).rounded()))%" }
        else { pctText = "—" }
        let weeklyText: String
        if let w = weeklyFraction { weeklyText = "·\(Int((w * 100).rounded()))%" }
        else { weeklyText = "" }

        let color: NSColor = {
            guard let f = fraction else { return .secondaryLabelColor }
            if f >= 0.9 { return .systemRed }
            if f >= 0.7 { return .systemOrange }
            return .labelColor
        }()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: color
        ]
        return NSAttributedString(string: "\(label) \(pctText)\(weeklyText)", attributes: attrs)
    }

    func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(refreshController: refreshController)
        }
        // Close the popover so the window doesn't open behind it.
        popover.performClose(nil)
        settingsWindowController?.show()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // When opened, kick a refresh so the user sees fresh numbers immediately.
            Task { await refreshController.refresh() }
        }
    }
}
