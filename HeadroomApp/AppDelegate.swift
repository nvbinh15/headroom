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
        let str = NSMutableAttributedString()

        var segments: [NSAttributedString] = []
        if state.claude.isConfigured {
            segments.append(coloredSegment(
                assetName: "ClaudeLogo",
                fraction: state.claude.fiveHour?.fraction,
                weeklyFraction: state.claude.weekly?.fraction
            ))
        }
        if state.codex.isConfigured {
            segments.append(coloredSegment(
                assetName: "OpenAILogo",
                fraction: state.codex.fiveHour?.fraction,
                weeklyFraction: state.codex.weekly?.fraction
            ))
        }

        if segments.isEmpty {
            statusItem?.button?.attributedTitle = NSAttributedString()
            statusItem?.button?.title = "Headroom"
            return
        }

        for (i, seg) in segments.enumerated() {
            if i > 0 { str.append(NSAttributedString(string: "  ")) }
            str.append(seg)
        }
        statusItem?.button?.attributedTitle = str
    }

    private func coloredSegment(
        assetName: String,
        fraction: Double?,
        weeklyFraction: Double?
    ) -> NSAttributedString {
        let pctText: String = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let weeklyText: String = weeklyFraction.map { "·\(Int(($0 * 100).rounded()))%" } ?? ""

        let textColor: NSColor = {
            guard let f = fraction else { return .secondaryLabelColor }
            if f >= 0.9 { return .systemRed }
            if f >= 0.7 { return .systemOrange }
            return .labelColor
        }()
        // Logos stay white by default and only flip to the warning colors.
        let iconColor: NSColor = {
            guard let f = fraction else { return .secondaryLabelColor }
            if f >= 0.9 { return .systemRed }
            if f >= 0.7 { return .systemOrange }
            return .white
        }()

        let result = NSMutableAttributedString()

        if let image = NSImage(named: assetName) {
            let size = NSSize(width: 14, height: 14)
            let tinted = image.tinted(with: iconColor, size: size)
            let attachment = NSTextAttachment()
            attachment.image = tinted
            // Lift so the glyph baselines with the percentage text.
            attachment.bounds = CGRect(x: 0, y: -2, width: size.width, height: size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " "))
        }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: textColor
        ]
        result.append(NSAttributedString(string: "\(pctText)\(weeklyText)", attributes: textAttrs))
        return result
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
