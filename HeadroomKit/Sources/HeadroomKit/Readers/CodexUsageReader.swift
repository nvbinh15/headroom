import Foundation

public struct CodexUsageReader: Sendable {
    public let sessionsDir: URL

    public init(sessionsDir: URL? = nil) {
        if let dir = sessionsDir {
            self.sessionsDir = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.sessionsDir = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        }
    }

    public func read() -> ProviderUsage {
        guard FileManager.default.fileExists(atPath: sessionsDir.path) else {
            return ProviderUsage(note: "no ~/.codex/sessions directory")
        }
        let files = recentSessionFiles()
        guard !files.isEmpty else {
            return ProviderUsage(note: "no recent codex sessions")
        }

        // Walk files newest → oldest, return the first rate_limits we find.
        for file in files {
            if let snapshot = latestRateLimits(in: file) {
                return ProviderUsage(
                    fiveHour: snapshot.primary,
                    weekly: snapshot.secondary,
                    note: "codex API"
                )
            }
        }
        return ProviderUsage(note: "no rate_limits in recent sessions")
    }

    /// Files modified within the last 7 days, sorted newest first.
    private func recentSessionFiles() -> [URL] {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate,
                  mtime > cutoff else { continue }
            results.append((url, mtime))
        }
        return results.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private struct Snapshot {
        let primary: WindowUsage
        let secondary: WindowUsage?
    }

    /// Streams a JSONL file backwards (last line first) to find the most recent rate_limits.
    /// We don't need to fully parse — we use a substring match before invoking JSONDecoder
    /// to keep this fast over multi-MB files.
    private func latestRateLimits(in file: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // Iterate lines newest first.
        let lines = text.split(omittingEmptySubsequences: true) { $0.isNewline }
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            if let snap = decodeSnapshot(from: line) {
                return snap
            }
        }
        return nil
    }

    private func decodeSnapshot<S: StringProtocol>(from line: S) -> Snapshot? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return nil }
        // The rate_limits object can sit anywhere in the event. Walk recursively.
        guard let rl = findRateLimits(any) else { return nil }

        let primaryWindow = decodeWindow(rl["primary"])
        let secondaryWindow = decodeWindow(rl["secondary"])
        guard let primary = primaryWindow else { return nil }
        return Snapshot(primary: primary, secondary: secondaryWindow)
    }

    private func findRateLimits(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let rl = dict["rate_limits"] as? [String: Any] {
                return rl
            }
            for (_, v) in dict {
                if let found = findRateLimits(v) { return found }
            }
        } else if let array = value as? [Any] {
            for v in array {
                if let found = findRateLimits(v) { return found }
            }
        }
        return nil
    }

    private func decodeWindow(_ raw: Any?) -> WindowUsage? {
        guard let dict = raw as? [String: Any] else { return nil }
        let pct = (dict["used_percent"] as? Double) ?? Double(dict["used_percent"] as? Int ?? 0)
        let windowMinutes = (dict["window_minutes"] as? Int) ?? Int(dict["window_minutes"] as? Double ?? 0)
        let resets = dict["resets_at"] as? Double ?? Double(dict["resets_at"] as? Int ?? 0)
        var resetsAt: Date? = resets > 0 ? Date(timeIntervalSince1970: resets) : nil
        var fraction = pct / 100.0

        // Snapshots are emitted on each Codex API call. If no Codex activity
        // has happened since the window's resets_at, the bucket has rolled to
        // 0% — but Codex's 5h window is *rolling* (anchored to the next
        // request), not a fixed cadence. We don't know when the new window
        // will start, so don't fabricate one. Drop resetsAt; the caller
        // displays no countdown rather than a phantom value.
        if let reset = resetsAt, reset < Date() {
            fraction = 0
            resetsAt = nil
        }

        return WindowUsage(
            fraction: fraction,
            tokensUsed: nil,
            tokensLimit: nil,
            resetsAt: resetsAt,
            windowMinutes: windowMinutes
        )
    }
}
