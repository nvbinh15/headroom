import AppKit
import Combine
import SwiftUI
import HeadroomKit

/// The fixed set of colours a menu-bar glyph can take, keyed so tinted images
/// can be cached instead of re-rendered offscreen on every refresh tick.
private enum IconTint: String {
    case normal, warning, critical, muted

    var color: NSColor {
        switch self {
        case .normal: return .white
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .muted: return .secondaryLabelColor
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let refreshController = RefreshController()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindowController: SettingsWindowController?
    private var cancellables: Set<AnyCancellable> = []
    private var statusUpdateScheduled = false
    /// Cache of recoloured menu-bar glyphs, keyed by asset + tint + appearance.
    private var tintedImageCache: [String: NSImage] = [:]

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

        // Re-render the status item when usage or menu-bar prefs change. A
        // single objectWillChange subscription covers every @Published property;
        // updates are coalesced so several changes in one runloop turn (e.g. a
        // refresh touching multiple fields) trigger just one redraw.
        refreshController.objectWillChange
            .sink { [weak self] in self?.scheduleStatusItemUpdate() }
            .store(in: &cancellables)
        updateStatusItemTitle()

        refreshController.start()
    }

    /// Coalesces status-item redraws to one per runloop turn. objectWillChange
    /// fires in `willSet`, so the deferred task also guarantees we read the
    /// already-updated property values.
    private func scheduleStatusItemUpdate() {
        guard !statusUpdateScheduled else { return }
        statusUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.statusUpdateScheduled = false
            self.updateStatusItemTitle()
        }
    }

    @MainActor
    private func updateStatusItemTitle() {
        let state = refreshController.visibleState()
        let density = refreshController.menuBarDensity
        let fractionStyle: UsageFractionStyle = state.showRemainingPercent ? .remaining : .used

        statusItem?.button?.toolTip = menuBarTooltip(for: state, density: density, style: fractionStyle)

        if density == .hidden {
            let worst = worstUsageFraction(in: state)
            statusItem?.button?.title = ""
            statusItem?.button?.attributedTitle = headroomIconSegment(warningFraction: worst)
            return
        }

        let str = NSMutableAttributedString()

        var segments: [NSAttributedString] = []
        if state.claude.isConfigured {
            segments.append(coloredSegment(
                assetName: "ClaudeLogo",
                fraction: state.claude.fiveHour?.fraction,
                weeklyFraction: state.claude.weekly?.fraction,
                density: density,
                style: fractionStyle
            ))
        }
        if state.codex.isConfigured {
            segments.append(coloredSegment(
                assetName: "OpenAILogo",
                fraction: state.codex.fiveHour?.fraction,
                weeklyFraction: state.codex.weekly?.fraction,
                density: density,
                style: fractionStyle
            ))
        }
        if state.cursor.isConfigured {
            segments.append(coloredSegment(
                assetName: "CursorLogo",
                fraction: state.cursor.fiveHour?.fraction,
                weeklyFraction: state.cursor.weekly?.fraction,
                density: density,
                style: fractionStyle
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
        density: MenuBarDensity,
        style: UsageFractionStyle
    ) -> NSAttributedString {
        let warningFraction = max(fraction ?? 0, weeklyFraction ?? 0)
        let displayFraction = UsageDisplay.displayFraction(fraction ?? weeklyFraction, style: style)

        let pctText = UsageDisplay.formatFraction(fraction ?? weeklyFraction, style: style)
        let weeklyText: String = {
            guard density == .full, let weeklyFraction else { return "" }
            return "·\(UsageDisplay.formatFraction(weeklyFraction, style: style))"
        }()

        let textColor: NSColor = {
            guard displayFraction != nil || weeklyFraction != nil else { return .secondaryLabelColor }
            if warningFraction >= 0.9 { return .systemRed }
            if warningFraction >= 0.7 { return .systemOrange }
            return .labelColor
        }()
        let iconTint: IconTint = {
            guard displayFraction != nil || weeklyFraction != nil else { return .muted }
            if warningFraction >= 0.9 { return .critical }
            if warningFraction >= 0.7 { return .warning }
            return .normal
        }()

        let result = NSMutableAttributedString()

        if let tinted = tintedMenuBarImage(named: assetName, tint: iconTint) {
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = CGRect(x: 0, y: -2, width: tinted.size.width, height: tinted.size.height)
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
        let iconTint: IconTint = {
            guard let f = warningFraction else { return .normal }
            if f >= 0.9 { return .critical }
            if f >= 0.7 { return .warning }
            return .normal
        }()

        let result = NSMutableAttributedString()
        if let tinted = tintedMenuBarImage(named: "HeadroomLogo", tint: iconTint) {
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = CGRect(x: 0, y: -2, width: tinted.size.width, height: tinted.size.height)
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    /// Returns the menu-bar glyph for `assetName` recoloured for `tint`, drawing
    /// it offscreen only once per (asset, tint, appearance) combination. Without
    /// this the icons were re-tinted on every refresh tick and preference change.
    private func tintedMenuBarImage(named assetName: String, tint: IconTint) -> NSImage? {
        let appearance = statusItem?.button?.effectiveAppearance.name.rawValue ?? "default"
        let key = "\(assetName)|\(tint.rawValue)|\(appearance)"
        if let cached = tintedImageCache[key] { return cached }
        guard let image = NSImage(named: assetName) else { return nil }
        let tinted = image.tinted(with: tint.color, size: NSSize(width: 14, height: 14))
        tintedImageCache[key] = tinted
        return tinted
    }

    private func worstUsageFraction(in state: UsageState) -> Double? {
        var values: [Double] = []
        for usage in [state.claude, state.codex, state.cursor] where usage.isConfigured {
            if let fraction = usage.fiveHour?.fraction { values.append(fraction) }
            if let fraction = usage.weekly?.fraction { values.append(fraction) }
        }
        return values.max()
    }

    private func menuBarTooltip(
        for state: UsageState,
        density: MenuBarDensity,
        style: UsageFractionStyle
    ) -> String? {
        guard density == .hidden || density == .iconsOnly else { return nil }
        let summary = UsageDisplay.menuBarSummary(
            state: state,
            showClaude: refreshController.menuBarShowClaude,
            showCodex: refreshController.menuBarShowCodex,
            showCursor: refreshController.menuBarShowCursor,
            style: style
        )
        return summary.isEmpty ? "Headroom" : summary
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
