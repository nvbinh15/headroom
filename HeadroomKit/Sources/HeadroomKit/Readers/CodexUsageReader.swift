import Foundation

public struct CodexUsageReader: Sendable {
    public let sessionsDir: URL

    public init(sessionsDir: URL? = nil) {
        if let dir = sessionsDir {
            self.sessionsDir = dir
        } else {
            self.sessionsDir = CodexAuth.codexHome().appendingPathComponent("sessions", isDirectory: true)
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
                // Codex puts the currently-enforced bucket in the `primary` slot,
                // so classify by window length rather than by position.
                var fiveHour: WindowUsage?
                var weekly: WindowUsage?
                for w in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
                    if w.windowMinutes >= 6 * 24 * 60 {
                        weekly = w
                    } else {
                        fiveHour = w
                    }
                }
                return ProviderUsage(
                    fiveHour: fiveHour,
                    weekly: weekly,
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

    /// Scans a JSONL file backwards (last line first) to find the most recent
    /// rate_limits, without materializing the whole file as a String or as an
    /// array of lines. Each `\n`-delimited line is checked for the
    /// `"rate_limits"` substring before invoking the JSON parser, so this stays
    /// fast and low-allocation over multi-MB session files.
    private func latestRateLimits(in file: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let needle = Array("\"rate_limits\"".utf8)
        let newline = UInt8(ascii: "\n")

        return data.withUnsafeBytes { rawBuffer -> Snapshot? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard let base = bytes.baseAddress else { return nil }
            var end = bytes.count
            while end > 0 {
                // The current line spans [start, end); walk back to the newline
                // that precedes it (or the start of the file).
                var start = end
                while start > 0 && bytes[start - 1] != newline { start -= 1 }
                if end > start,
                   bufferContains(bytes, start: start, end: end, needle: needle) {
                    let lineData = Data(bytes: base.advanced(by: start), count: end - start)
                    if let snap = decodeSnapshot(fromUTF8: lineData) { return snap }
                }
                if start == 0 { break }
                end = start - 1 // step over the newline onto the previous line
            }
            return nil
        }
    }

    /// Naive substring search of `needle` within `bytes[start..<end]`.
    private func bufferContains(
        _ bytes: UnsafeBufferPointer<UInt8>,
        start: Int,
        end: Int,
        needle: [UInt8]
    ) -> Bool {
        let n = needle.count
        guard n > 0, end - start >= n else { return false }
        let first = needle[0]
        var i = start
        let last = end - n
        while i <= last {
            if bytes[i] == first {
                var k = 1
                while k < n && bytes[i + k] == needle[k] { k += 1 }
                if k == n { return true }
            }
            i += 1
        }
        return false
    }

    private func decodeSnapshot(fromUTF8 data: Data) -> Snapshot? {
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
