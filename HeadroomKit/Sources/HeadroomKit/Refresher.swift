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
        /// Disk path for caching the latest Cursor API response.
        public var cursorCacheURL: URL

        public init(
            claudeOverrideLimits: PlanLimits? = nil,
            minOAuthInterval: TimeInterval = 5 * 60,
            claudeCacheURL: URL? = nil,
            codexCacheURL: URL? = nil,
            cursorCacheURL: URL? = nil
        ) {
            self.claudeOverrideLimits = claudeOverrideLimits
            self.minOAuthInterval = minOAuthInterval

            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let dir = caches.appendingPathComponent("Headroom", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.claudeCacheURL = claudeCacheURL ?? dir.appendingPathComponent("claude-oauth-usage.json")
            self.codexCacheURL = codexCacheURL ?? dir.appendingPathComponent("codex-wham-usage.json")
            self.cursorCacheURL = cursorCacheURL ?? dir.appendingPathComponent("cursor-usage.json")
        }
    }

    public let configuration: Configuration
    private let claudeClient: OAuthUsageClient
    private let codexClient: CodexUsageClient
    private let cursorClient: CursorUsageClient

    public init(
        configuration: Configuration = .init(),
        claudeClient: OAuthUsageClient = .init(),
        codexClient: CodexUsageClient = .init(),
        cursorClient: CursorUsageClient = .init()
    ) {
        self.configuration = configuration
        self.claudeClient = claudeClient
        self.codexClient = codexClient
        self.cursorClient = cursorClient
    }

    public func snapshot() async -> UsageState {
        async let codex = readCodex()
        async let claude = readClaude()
        async let cursor = readCursor()
        let (c, x, u) = await (claude, codex, cursor)
        return UsageState(claude: c, codex: x, cursor: u)
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
        // Token unreadable, but a prior API response may still be on disk.
        if let cached: CachedClaudeResponse = readCache(at: configuration.claudeCacheURL) {
            let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
            return claudeProviderUsage(from: cached.response, plan: plan, source: "API · stale \(age)m (no keychain auth)")
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
        let weeklyBucket = r.seven_day
            ?? r.seven_day_oauth_apps
            ?? r.seven_day_sonnet
            ?? r.seven_day_opus
            ?? r.seven_day_design
            ?? r.seven_day_routines
        let weekly = weeklyBucket.flatMap { b -> WindowUsage? in
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
        if var auth = CodexAuth.loadDefault() {
            if let cached: CachedCodexResponse = readCache(at: configuration.codexCacheURL),
               Date().timeIntervalSince(cached.fetchedAt) < configuration.minOAuthInterval {
                return codexProviderUsage(from: cached.response, fetchedAt: cached.fetchedAt, source: "API · cached")
            }

            if auth.needsRefresh(),
               let refreshed = await refreshCodexAuth(auth) {
                auth = refreshed
            }

            switch await codexClient.fetch(auth: auth) {
            case .success(let response):
                let now = Date()
                writeCache(CachedCodexResponse(fetchedAt: now, response: response), at: configuration.codexCacheURL)
                return codexProviderUsage(from: response, fetchedAt: now, source: "API")
            case .failure(let err):
                if shouldRefreshAfterCodexFailure(err),
                   let refreshed = await refreshCodexAuth(auth),
                   refreshed.accessToken != auth.accessToken {
                    switch await codexClient.fetch(auth: refreshed) {
                    case .success(let response):
                        let now = Date()
                        writeCache(CachedCodexResponse(fetchedAt: now, response: response), at: configuration.codexCacheURL)
                        return codexProviderUsage(from: response, fetchedAt: now, source: "API · refreshed")
                    case .failure:
                        break
                    }
                }
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
        let codexSessions = CodexAuth.codexHome().appendingPathComponent("sessions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: codexSessions.path) {
            return ProviderUsage(note: "Codex not signed in", isConfigured: false)
        }
        var fallback = CodexUsageReader().read()
        fallback.note = (fallback.note ?? "codex") + " · no auth"
        return fallback
    }

    private func refreshCodexAuth(_ auth: CodexAuth) async -> CodexAuth? {
        guard auth.canRefresh else { return nil }
        guard let refreshed = try? await CodexTokenRefresher.refresh(auth) else { return nil }
        try? refreshed.save()
        return refreshed
    }

    private func shouldRefreshAfterCodexFailure(_ err: CodexUsageClient.FetchError) -> Bool {
        switch err {
        case .http(let code):
            return code == 401 || code == 403
        case .missingAuth, .decode(_), .network(_):
            return false
        }
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
        // /wham/usage surfaces the *currently-enforced* bucket as `primary_window`
        // — when the weekly cap is hit, the weekly bucket arrives in the primary
        // slot. Classify by window length, not by position.
        var fiveHour: WindowUsage?
        var weekly: WindowUsage?
        for raw in [r.rate_limit?.primary_window, r.rate_limit?.secondary_window] {
            guard let raw, let parsed = window(from: raw, fetchedAt: fetchedAt) else { continue }
            if isCodexWeeklyWindow(seconds: raw.limit_window_seconds, minutes: parsed.windowMinutes) {
                weekly = parsed
            } else {
                fiveHour = parsed
            }
        }
        let plan = r.plan_type.map { "Codex \($0)" } ?? "Codex"
        return ProviderUsage(fiveHour: fiveHour, weekly: weekly, note: "\(plan) · \(source)")
    }

    private func isCodexWeeklyWindow(seconds: Int?, minutes: Int) -> Bool {
        if let seconds {
            return seconds >= 6 * 24 * 60 * 60
        }
        return minutes >= 6 * 24 * 60
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

    // MARK: - Cursor

    private func readCursor() async -> ProviderUsage {
        guard var credentials = CursorCredentialsLoader.load() else {
            if !CursorCredentialsLoader.cursorAppSupportExists() {
                return ProviderUsage(note: "Cursor not signed in", isConfigured: false)
            }
            return ProviderUsage(note: "Cursor not signed in", isConfigured: false)
        }

        if let cached: CachedCursorResponse = readCache(at: configuration.cursorCacheURL),
           Date().timeIntervalSince(cached.fetchedAt) < configuration.minOAuthInterval {
            return cursorProviderUsage(from: cached, source: "API · cached")
        }

        if credentials.needsRefresh(),
           let refreshed = await refreshCursorAuth(credentials) {
            credentials = refreshed
        }

        switch await fetchCursorUsage(credentials: credentials) {
        case .success(let cached):
            writeCache(cached, at: configuration.cursorCacheURL)
            return cursorProviderUsage(from: cached, source: "API")
        case .failure(let err):
            if shouldRefreshAfterCursorFailure(err),
               let refreshed = await refreshCursorAuth(credentials),
               refreshed.accessToken != credentials.accessToken {
                switch await fetchCursorUsage(credentials: refreshed) {
                case .success(let cached):
                    writeCache(cached, at: configuration.cursorCacheURL)
                    return cursorProviderUsage(from: cached, source: "API · refreshed")
                case .failure:
                    break
                }
            }
            if let cached: CachedCursorResponse = readCache(at: configuration.cursorCacheURL) {
                let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
                return cursorProviderUsage(from: cached, source: "API · stale \(age)m (\(describeCursor(err)))")
            }
            switch await fetchCursorLegacyUsage(credentials: credentials) {
            case .success(let usage):
                return usage
            case .failure:
                return ProviderUsage(
                    note: "Cursor · API \(describeCursor(err))",
                    isConfigured: true
                )
            }
        }
    }

    private func fetchCursorUsage(
        credentials: CursorCredentials
    ) async -> Result<CachedCursorResponse, CursorUsageClient.FetchError> {
        switch await cursorClient.fetchCurrentPeriodUsage(token: credentials.accessToken) {
        case .success(let usage):
            guard usage.planUsage != nil else {
                return .failure(.emptyUsage)
            }
            let planName = await fetchCursorPlanName(token: credentials.accessToken)
            return .success(CachedCursorResponse(
                fetchedAt: Date(),
                usage: usage,
                planName: planName,
                membershipType: credentials.membershipType,
                legacyUsage: nil
            ))
        case .failure(let err):
            return .failure(err)
        }
    }

    private func fetchCursorLegacyUsage(
        credentials: CursorCredentials
    ) async -> Result<ProviderUsage, CursorUsageClient.FetchError> {
        switch await cursorClient.fetchLegacyUsage(token: credentials.accessToken) {
        case .success(let legacy):
            guard let usage = CursorUsageMapper.providerUsage(
                from: legacy,
                membershipType: credentials.membershipType,
                source: "legacy API"
            ) else {
                return .failure(.emptyUsage)
            }
            return .success(usage)
        case .failure(let err):
            return .failure(err)
        }
    }

    private func fetchCursorPlanName(token: String) async -> String? {
        switch await cursorClient.fetchPlanInfo(token: token) {
        case .success(let response):
            return response.planInfo?.planName
        case .failure:
            return nil
        }
    }

    private func refreshCursorAuth(_ credentials: CursorCredentials) async -> CursorCredentials? {
        guard credentials.canRefresh else { return nil }
        guard let refreshed = try? await CursorTokenRefresher.refresh(credentials) else { return nil }
        try? CursorCredentialsLoader.save(refreshed)
        return refreshed
    }

    private func shouldRefreshAfterCursorFailure(_ err: CursorUsageClient.FetchError) -> Bool {
        switch err {
        case .http(let code):
            return code == 401 || code == 403
        case .missingAuth, .decode(_), .network(_), .emptyUsage:
            return false
        }
    }

    private func describeCursor(_ err: CursorUsageClient.FetchError) -> String {
        switch err {
        case .missingAuth: return "no auth"
        case .http(let code): return "HTTP \(code)"
        case .decode: return "decode error"
        case .network: return "network error"
        case .emptyUsage: return "empty usage"
        }
    }

    private func cursorProviderUsage(from cached: CachedCursorResponse, source: String) -> ProviderUsage {
        if let mapped = CursorUsageMapper.providerUsage(
            from: cached.usage,
            planName: cached.planName,
            membershipType: cached.membershipType,
            source: source
        ) {
            return mapped
        }
        if let legacy = cached.legacyUsage,
           let mapped = CursorUsageMapper.providerUsage(
               from: legacy,
               membershipType: cached.membershipType,
               source: source
           ) {
            return mapped
        }
        return ProviderUsage(note: "Cursor · \(source)", isConfigured: true)
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

    private struct CachedCursorResponse: Codable {
        let fetchedAt: Date
        let usage: CursorUsageClient.PeriodUsageResponse
        let planName: String?
        let membershipType: String?
        let legacyUsage: CursorUsageClient.LegacyUsageResponse?
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
