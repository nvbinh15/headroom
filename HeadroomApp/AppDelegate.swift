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
        // Bail out if another Headroom (same bundle ID) is already running —
        // otherwise both instances install a status item and a popover, which
        // shows up as a duplicated menu-bar widget on wide displays.
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }

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

        // Re-render the status item when usage or menu-bar prefs change.
        Task { @MainActor in
            for await _ in refreshController.$state.values {
                self.updateStatusItemTitle()
            }
        }
        Task { @MainActor in
            for await _ in refreshController.$menuBarDensity.values {
                self.updateStatusItemTitle()
            }
        }
        Task { @MainActor in
            for await _ in refreshController.$menuBarShowClaude.values {
                self.updateStatusItemTitle()
            }
        }
        Task { @MainActor in
            for await _ in refreshController.$menuBarShowCodex.values {
                self.updateStatusItemTitle()
            }
        }
        Task { @MainActor in
            for await _ in refreshController.$menuBarShowCursor.values {
                self.updateStatusItemTitle()
            }
        }

        refreshController.start()
    }

    @MainActor
    private func updateStatusItemTitle() {
        let state = refreshController.state
        let density = refreshController.menuBarDensity

        if density == .hidden {
            let worst = worstUsageFraction(in: state)
            statusItem?.button?.title = ""
            statusItem?.button?.attributedTitle = headroomIconSegment(warningFraction: worst)
            return
        }

        let str = NSMutableAttributedString()

        var segments: [NSAttributedString] = []
        if state.claude.isConfigured, refreshController.menuBarShowClaude {
            segments.append(coloredSegment(
                assetName: "ClaudeLogo",
                fraction: state.claude.fiveHour?.fraction,
                weeklyFraction: state.claude.weekly?.fraction,
                density: density
            ))
        }
        if state.codex.isConfigured, refreshController.menuBarShowCodex {
            segments.append(coloredSegment(
                assetName: "OpenAILogo",
                fraction: state.codex.fiveHour?.fraction,
                weeklyFraction: state.codex.weekly?.fraction,
                density: density
            ))
        }
        if state.cursor.isConfigured, refreshController.menuBarShowCursor {
            segments.append(coloredSegment(
                assetName: "CursorLogo",
                fraction: state.cursor.fiveHour?.fraction,
                weeklyFraction: state.cursor.weekly?.fraction,
                density: density
            ))
        }

        if segments.isEmpty {
            statusItem?.button?.attributedTitle = NSAttributedString()
            statusItem?.button?.title = "Headroom"
            return
        }

        let separator = density == .full ? "  " : " "
        for (i, seg) in segments.enumerated() {
            if i > 0 { str.append(NSAttributedString(string: separator)) }
            str.append(seg)
        }
        statusItem?.button?.attributedTitle = str
    }

    private func coloredSegment(
        assetName: String,
        fraction: Double?,
        weeklyFraction: Double?,
        density: MenuBarDensity
    ) -> NSAttributedString {
        let warningFraction = max(fraction ?? 0, weeklyFraction ?? 0)
        let displayFraction = fraction ?? weeklyFraction

        let pctText: String = displayFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let weeklyText: String = {
            guard density == .full, let weeklyFraction else { return "" }
            return "·\(Int((weeklyFraction * 100).rounded()))%"
        }()

        let textColor: NSColor = {
            guard displayFraction != nil || weeklyFraction != nil else { return .secondaryLabelColor }
            if warningFraction >= 0.9 { return .systemRed }
            if warningFraction >= 0.7 { return .systemOrange }
            return .labelColor
        }()
        let iconColor: NSColor = {
            guard displayFraction != nil || weeklyFraction != nil else { return .secondaryLabelColor }
            if warningFraction >= 0.9 { return .systemRed }
            if warningFraction >= 0.7 { return .systemOrange }
            return .white
        }()

        let result = NSMutableAttributedString()

        if let image = NSImage(named: assetName) {
            let size = NSSize(width: 14, height: 14)
            let tinted = image.tinted(with: iconColor, size: size)
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = CGRect(x: 0, y: -2, width: size.width, height: size.height)
            result.append(NSAttributedString(attachment: attachment))
            if density != .iconsOnly {
                result.append(NSAttributedString(string: " "))
            }
        }

        guard density != .iconsOnly else { return result }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: textColor
        ]
        result.append(NSAttributedString(string: "\(pctText)\(weeklyText)", attributes: textAttrs))
        return result
    }

    private func headroomIconSegment(warningFraction: Double?) -> NSAttributedString {
        let iconColor: NSColor = {
            guard let f = warningFraction else { return .white }
            if f >= 0.9 { return .systemRed }
            if f >= 0.7 { return .systemOrange }
            return .white
        }()

        let result = NSMutableAttributedString()
        if let image = NSImage(named: "HeadroomLogo") {
            let size = NSSize(width: 14, height: 14)
            let tinted = image.tinted(with: iconColor, size: size)
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = CGRect(x: 0, y: -2, width: size.width, height: size.height)
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    private func worstUsageFraction(in state: UsageState) -> Double? {
        var values: [Double] = []
        for usage in [state.claude, state.codex, state.cursor] where usage.isConfigured {
            if let fraction = usage.fiveHour?.fraction { values.append(fraction) }
            if let fraction = usage.weekly?.fraction { values.append(fraction) }
        }
        return values.max()
    }

    func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(refreshController: refreshController)
        }
        // Close the popover so the window doesn't open behind it.
        popover.performClose(nil)
        settingsWindowController?.show()
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let myID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == myID && app.processIdentifier != myPID
        }
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
