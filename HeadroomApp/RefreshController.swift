import Foundation
import AppKit
import SwiftUI
import WidgetKit
import HeadroomKit

@MainActor
final class RefreshController: ObservableObject {
    @Published private(set) var state: UsageState = .empty
    @Published private(set) var isRefreshing: Bool = false
    @Published var refreshIntervalSeconds: Double {
        didSet {
            UserDefaults.standard.set(refreshIntervalSeconds, forKey: "refreshIntervalSeconds")
            restartTimer()
        }
    }
    @Published var menuBarDensity: MenuBarDensity {
        didSet { MenuBarPreferences.save(density: menuBarDensity) }
    }
    @Published var menuBarShowClaude: Bool {
        didSet {
            MenuBarPreferences.save(showClaude: menuBarShowClaude)
            providerVisibilityChanged()
        }
    }
    @Published var menuBarShowCodex: Bool {
        didSet {
            MenuBarPreferences.save(showCodex: menuBarShowCodex)
            providerVisibilityChanged()
        }
    }
    @Published var menuBarShowCursor: Bool {
        didSet {
            MenuBarPreferences.save(showCursor: menuBarShowCursor)
            providerVisibilityChanged()
        }
    }
    @Published var showRemainingPercent: Bool {
        didSet { DisplayPreferences.save(showRemainingPercent: showRemainingPercent) }
    }
    @Published var lowHeadroomWarnings: Bool {
        didSet { DisplayPreferences.save(lowHeadroomWarnings: lowHeadroomWarnings) }
    }

    let refresher: Refresher
    private let stateURL: URL
    private var timer: Timer?

    init() {
        let configured = UserDefaults.standard.double(forKey: "refreshIntervalSeconds")
        self.refreshIntervalSeconds = configured > 0 ? configured : 60
        self.menuBarDensity = MenuBarPreferences.loadDensity()
        self.menuBarShowClaude = MenuBarPreferences.loadShowClaude()
        self.menuBarShowCodex = MenuBarPreferences.loadShowCodex()
        self.menuBarShowCursor = MenuBarPreferences.loadShowCursor()
        self.showRemainingPercent = DisplayPreferences.loadShowRemainingPercent()
        self.lowHeadroomWarnings = DisplayPreferences.loadLowHeadroomWarnings()

        self.stateURL = SharedStatePath.url
        self.refresher = Refresher(configuration: .init(minOAuthInterval: 5 * 60))

        // Load any prior state synchronously so the menu bar doesn't flash empty.
        if let data = try? Data(contentsOf: stateURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let prior = try? decoder.decode(UsageState.self, from: data) {
                self.state = prior
            }
        }
    }

    func start() {
        Task { await refresh() }
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let next = await refresher.snapshot(showRemainingPercent: showRemainingPercent)
        applyDefaultDensityIfNeeded(state: next)
        let previous = self.state
        self.state = next

        // The live endpoints are throttled to a few minutes, so most ticks just
        // re-read the same cache and produce identical numbers — only the
        // timestamp moved. Skip the disk write + cross-process widget reload
        // unless the visible content actually changed.
        let nextVisible = visibleState(from: next)
        if !nextVisible.hasSameContent(as: visibleState(from: previous)) {
            writeState(next)
            WidgetCenter.shared.reloadAllTimelines()
        }
        UsageNotifier.shared.evaluate(state: nextVisible, enabled: lowHeadroomWarnings)
    }

    private func applyDefaultDensityIfNeeded(state: UsageState) {
        guard !DisplayPreferences.isDensityExplicitlySet() else { return }
        let configuredCount = [
            menuBarShowClaude ? state.claude : nil,
            menuBarShowCodex ? state.codex : nil,
            menuBarShowCursor ? state.cursor : nil
        ].compactMap { $0 }.filter(\.isConfigured).count
        if configuredCount >= 3, menuBarDensity != .hidden {
            menuBarDensity = .hidden
        }
    }

    private func writeState(_ state: UsageState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(visibleState(from: state)) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    func visibleState(from state: UsageState? = nil) -> UsageState {
        let source = state ?? self.state
        return UsageState(
            claude: menuBarShowClaude ? source.claude : ProviderUsage(isConfigured: false),
            codex: menuBarShowCodex ? source.codex : ProviderUsage(isConfigured: false),
            cursor: menuBarShowCursor ? source.cursor : ProviderUsage(isConfigured: false),
            showRemainingPercent: source.showRemainingPercent,
            lastUpdated: source.lastUpdated
        )
    }

    private func providerVisibilityChanged() {
        writeState(state)
        UsageNotifier.shared.evaluate(state: visibleState(), enabled: lowHeadroomWarnings)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Settings actions

    func clearAPICachesAndRefresh() async {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("claude-oauth-usage.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("codex-wham-usage.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("cursor-usage.json"))
        await refresh()
    }

    func rereadClaudeLoginAndRefresh() async {
        KeychainCredentialsLoader.deleteHeadroomCredentialsFile()
        await clearAPICachesAndRefresh()
    }

    /// Reveals the shared-state directory in Finder.
    func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([stateURL])
    }
}
