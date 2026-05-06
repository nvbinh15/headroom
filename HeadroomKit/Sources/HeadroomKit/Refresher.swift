import Foundation

/// High-level entry point used by both the menu-bar app and the CLI.
public actor Refresher {
    public struct Configuration: Sendable {
        public var claudeOverrideLimits: PlanLimits?
        /// How often we'll hit the live usage endpoints at most.
        public var minOAuthInterval: TimeInterval
        /// Disk path for caching the latest Claude API response.
        public var claudeCacheURL: URL
        /// Disk path for caching the latest Codex API response.
        public var codexCacheURL: URL

        public init(
            claudeOverrideLimits: PlanLimits? = nil,
            minOAuthInterval: TimeInterval = 5 * 60,
            claudeCacheURL: URL? = nil,
            codexCacheURL: URL? = nil
        ) {
            self.claudeOverrideLimits = claudeOverrideLimits
            self.minOAuthInterval = minOAuthInterval

            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let dir = caches.appendingPathComponent("Headroom", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.claudeCacheURL = claudeCacheURL ?? dir.appendingPathComponent("claude-oauth-usage.json")
            self.codexCacheURL = codexCacheURL ?? dir.appendingPathComponent("codex-wham-usage.json")
        }
    }

    public let configuration: Configuration
    private let claudeClient: OAuthUsageClient
    private let codexClient: CodexUsageClient

    public init(
        configuration: Configuration = .init(),
        claudeClient: OAuthUsageClient = .init(),
        codexClient: CodexUsageClient = .init()
    ) {
        self.configuration = configuration
        self.claudeClient = claudeClient
        self.codexClient = codexClient
    }

    public func snapshot() async -> UsageState {
        async let codex = readCodex()
        async let claude = readClaude()
        let (c, x) = await (claude, codex)
        return UsageState(claude: c, codex: x)
    }

    // MARK: - Claude

    private func readClaude() async -> ProviderUsage {
        let creds = KeychainCredentialsLoader.loadClaude()
        let plan = creds?.plan ?? .unknown

        if let token = creds?.accessToken {
            if let cached: CachedClaudeResponse = readCache(at: configuration.claudeCacheURL),
               Date().timeIntervalSince(cached.fetchedAt) < configuration.minOAuthInterval {
                return claudeProviderUsage(from: cached.response, plan: plan, source: "API · cached")
            }
            switch await claudeClient.fetch(token: token) {
            case .success(let response):
                writeCache(CachedClaudeResponse(fetchedAt: Date(), response: response), at: configuration.claudeCacheURL)
                return claudeProviderUsage(from: response, plan: plan, source: "API")
            case .failure(let err):
                if let cached: CachedClaudeResponse = readCache(at: configuration.claudeCacheURL) {
                    let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
                    return claudeProviderUsage(from: cached.response, plan: plan, source: "API · stale \(age)m (\(describeClaude(err)))")
                }
                return localClaudeEstimate(plan: plan, note: "estimate — API \(describeClaude(err))")
            }
        }
        // No keychain creds. If the user has never run Claude Code locally either,
        // treat the provider as unconfigured so the UI hides it.
        let claudeProjects = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        if !FileManager.default.fileExists(atPath: claudeProjects.path) {
            return ProviderUsage(note: "Claude not signed in", isConfigured: false)
        }
        return localClaudeEstimate(plan: plan, note: "estimate — no keychain auth")
    }

    private func describeClaude(_ err: OAuthUsageClient.FetchError) -> String {
        switch err {
        case .http(let code): return "HTTP \(code)"
        case .decode: return "decode error"
        case .network: return "network error"
        }
    }

    private func claudeProviderUsage(from r: OAuthUsageClient.Response, plan: ClaudePlan, source: String) -> ProviderUsage {
        let fiveHour = r.five_hour.flatMap { b -> WindowUsage? in
            guard let util = b.utilization else { return nil }
            return WindowUsage(fraction: util / 100.0, resetsAt: b.resets_at, windowMinutes: 300)
        }
        let weekly = r.seven_day.flatMap { b -> WindowUsage? in
            guard let util = b.utilization else { return nil }
            return WindowUsage(fraction: util / 100.0, resetsAt: b.resets_at, windowMinutes: 10080)
        }
        return ProviderUsage(fiveHour: fiveHour, weekly: weekly, note: "\(plan.displayName) · \(source)")
    }

    private func localClaudeEstimate(plan: ClaudePlan, note: String) -> ProviderUsage {
        let limits = configuration.claudeOverrideLimits ?? PlanLimits.defaults(for: plan)
        var usage = ClaudeUsageReader(plan: plan, limits: limits).read()
        usage.note = "\(plan.displayName) · \(note)"
        return usage
    }

    // MARK: - Codex

    private func readCodex() async -> ProviderUsage {
        if let auth = CodexAuth.loadDefault() {
            if let cached: CachedCodexResponse = readCache(at: configuration.codexCacheURL),
               Date().timeIntervalSince(cached.fetchedAt) < configuration.minOAuthInterval {
                return codexProviderUsage(from: cached.response, fetchedAt: cached.fetchedAt, source: "API · cached")
            }
            switch await codexClient.fetch(auth: auth) {
            case .success(let response):
                let now = Date()
                writeCache(CachedCodexResponse(fetchedAt: now, response: response), at: configuration.codexCacheURL)
                return codexProviderUsage(from: response, fetchedAt: now, source: "API")
            case .failure(let err):
                if let cached: CachedCodexResponse = readCache(at: configuration.codexCacheURL) {
                    let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
                    return codexProviderUsage(from: cached.response, fetchedAt: cached.fetchedAt, source: "API · stale \(age)m (\(describeCodex(err)))")
                }
                // Last resort — JSONL snapshot from the most recent session.
                var fallback = CodexUsageReader().read()
                fallback.note = (fallback.note ?? "") + " · API \(describeCodex(err))"
                return fallback
            }
        }
        // No auth.json. If the user has never run Codex locally either,
        // treat the provider as unconfigured so the UI hides it.
        let codexSessions = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: codexSessions.path) {
            return ProviderUsage(note: "Codex not signed in", isConfigured: false)
        }
        var fallback = CodexUsageReader().read()
        fallback.note = (fallback.note ?? "codex") + " · no auth"
        return fallback
    }

    private func describeCodex(_ err: CodexUsageClient.FetchError) -> String {
        switch err {
        case .missingAuth: return "no auth"
        case .http(let code): return "HTTP \(code)"
        case .decode: return "decode error"
        case .network: return "network error"
        }
    }

    private func codexProviderUsage(from r: CodexUsageClient.Response, fetchedAt: Date, source: String) -> ProviderUsage {
        let fiveHour = r.rate_limit?.primary_window.flatMap { window(from: $0, fetchedAt: fetchedAt) }
        let weekly = r.rate_limit?.secondary_window.flatMap { window(from: $0, fetchedAt: fetchedAt) }
        let plan = r.plan_type.map { "Codex \($0)" } ?? "Codex"
        return ProviderUsage(fiveHour: fiveHour, weekly: weekly, note: "\(plan) · \(source)")
    }

    private func window(from w: CodexUsageClient.Window, fetchedAt: Date) -> WindowUsage? {
        guard let pct = w.used_percent else { return nil }
        let secs = w.limit_window_seconds ?? 0
        // Prefer reset_after_seconds anchored to our fetch time. The server's
        // absolute reset_at is computed against the server clock, so any drift
        // between server and client (or, more importantly, between cache write
        // and cache read) shows up as a wrong countdown. Anchoring to fetchedAt
        // keeps the countdown accurate regardless.
        let resetsAt: Date?
        if let after = w.reset_after_seconds {
            resetsAt = fetchedAt.addingTimeInterval(TimeInterval(after))
        } else if let at = w.reset_at {
            resetsAt = Date(timeIntervalSince1970: at)
        } else {
            resetsAt = nil
        }
        return WindowUsage(
            fraction: pct / 100.0,
            resetsAt: resetsAt,
            windowMinutes: secs / 60
        )
    }

    // MARK: - Cache

    private struct CachedClaudeResponse: Codable {
        let fetchedAt: Date
        let response: OAuthUsageClient.Response
    }

    private struct CachedCodexResponse: Codable {
        let fetchedAt: Date
        let response: CodexUsageClient.Response
    }

    private func readCache<T: Codable>(at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func writeCache<T: Codable>(_ value: T, at url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
