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

    let refresher: Refresher
    private let stateURL: URL
    private var timer: Timer?

    init() {
        let configured = UserDefaults.standard.double(forKey: "refreshIntervalSeconds")
        self.refreshIntervalSeconds = configured > 0 ? configured : 60

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

        let next = await refresher.snapshot()
        self.state = next
        writeState(next)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func writeState(_ state: UsageState) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: - Settings actions

    /// Deletes the on-disk caches for the live API responses, then forces a
    /// refresh so the user sees fresh numbers immediately.
    func resetCachesAndRefresh() async {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("claude-oauth-usage.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("codex-wham-usage.json"))
        await refresh()
    }

    /// Reveals the shared-state directory in Finder.
    func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([stateURL])
    }
}
