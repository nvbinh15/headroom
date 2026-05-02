import Foundation

public struct ClaudeUsageReader: Sendable {
    public let projectsDir: URL
    public let plan: ClaudePlan
    public let limits: PlanLimits
    /// Override for testing.
    public let now: @Sendable () -> Date

    public init(
        projectsDir: URL? = nil,
        plan: ClaudePlan,
        limits: PlanLimits,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        if let dir = projectsDir {
            self.projectsDir = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.projectsDir = home.appendingPathComponent(".claude/projects", isDirectory: true)
        }
        self.plan = plan
        self.limits = limits
        self.now = now
    }

    public func read() -> ProviderUsage {
        let now = self.now()
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return ProviderUsage(note: "no ~/.claude/projects directory")
        }
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        let fiveHourAgo = now.addingTimeInterval(-5 * 3600)

        let files = sessionFiles(modifiedSince: weekAgo)
        var fiveHourTokens = 0
        var weeklyTokens = 0

        for file in files {
            for record in usageRecords(in: file) {
                guard record.timestamp >= weekAgo else { continue }
                weeklyTokens += record.totalTokens
                if record.timestamp >= fiveHourAgo {
                    fiveHourTokens += record.totalTokens
                }
            }
        }

        let fiveHour = WindowUsage(
            fraction: fraction(used: fiveHourTokens, limit: limits.fiveHourTokens),
            tokensUsed: fiveHourTokens,
            tokensLimit: limits.fiveHourTokens,
            resetsAt: nil, // rolling — no fixed reset
            windowMinutes: 300
        )
        let weekly: WindowUsage? = (limits.weeklyTokens != nil)
            ? WindowUsage(
                fraction: fraction(used: weeklyTokens, limit: limits.weeklyTokens),
                tokensUsed: weeklyTokens,
                tokensLimit: limits.weeklyTokens,
                resetsAt: nil,
                windowMinutes: 10080
            )
            : nil
        return ProviderUsage(
            fiveHour: fiveHour,
            weekly: weekly,
            note: "\(plan.displayName) · estimate from local jsonl"
        )
    }

    private func fraction(used: Int, limit: Int?) -> Double? {
        guard let limit, limit > 0 else { return nil }
        return min(Double(used) / Double(limit), 1.0)
    }

    private func sessionFiles(modifiedSince cutoff: Date) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate,
                  mtime >= cutoff else { continue }
            results.append(url)
        }
        return results
    }

    struct UsageRecord {
        let timestamp: Date
        let totalTokens: Int
    }

    private func usageRecords(in file: URL) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var out: [UsageRecord] = []
        out.reserveCapacity(64)

        // Avoid full JSON parse per line — only decode lines that mention "usage".
        text.enumerateLines { line, _ in
            guard line.contains("\"usage\"") else { return }
            guard let lineData = line.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }

            // Top-level timestamp on the JSONL record.
            guard let tsRaw = any["timestamp"] as? String,
                  let ts = parseISO8601(tsRaw) else { return }

            // The usage object is nested under "message".
            guard let message = any["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }

            // Skip synthetic messages (model "<synthetic>") — Claude Code emits these
            // for client-side bookkeeping and they always have zero tokens anyway.
            if let model = message["model"] as? String, model == "<synthetic>" { return }

            // Weight matches Anthropic's published cost ratios for Sonnet/Opus, which
            // also roughly tracks how each input type counts toward the rate-limit
            // window (cache reads are ~10% of fresh input, cache writes are ~125%).
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

            // Cache reads are ~10% of fresh input cost; output and fresh input count 1:1
            // for rate-limit purposes (the Claude /usage endpoint's percentages line up
            // with this weighting in practice).
            let weighted = Double(input)
                + Double(output)
                + Double(cacheWrite)
                + Double(cacheRead) * 0.1
            let total = Int(weighted.rounded())
            guard total > 0 else { return }
            out.append(UsageRecord(timestamp: ts, totalTokens: total))
        }
        return out
    }
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601FormatterNoFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseISO8601(_ s: String) -> Date? {
    iso8601Formatter.date(from: s) ?? iso8601FormatterNoFraction.date(from: s)
}
