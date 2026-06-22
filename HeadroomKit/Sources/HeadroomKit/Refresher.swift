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

    public func snapshot(showRemainingPercent: Bool = false) async -> UsageState {
        async let codex = readCodex()
        async let claude = readClaude()
        async let cursor = readCursor()
        let (c, x, u) = await (claude, codex, cursor)
        return UsageState(
            claude: c,
            codex: x,
            cursor: u,
            showRemainingPercent: showRemainingPercent
        )
    }

    // MARK: - Claude

    private func readClaude() async -> ProviderUsage {
        var creds = KeychainCredentialsLoader.loadClaude()
        var plan = creds?.plan ?? .unknown
        let planLabel = plan.displayName

        if let current = creds,
           current.needsRefresh(),
           current.canRefresh,
           let refreshed = await refreshClaudeAuth(current) {
            creds = refreshed
            plan = refreshed.plan
        }

        // Read the on-disk cache once and reuse it for both the freshness check
        // and the stale fallback below.
        let cached: CachedClaudeResponse? = readCache(at: configuration.claudeCacheURL)

        if let token = creds?.accessToken {
            if let cached,
               Date().timeIntervalSince(cached.fetchedAt) < configuration.minOAuthInterval {
                return claudeProviderUsage(
                    from: cached.response,
                    planLabel: planLabel,
                    freshness: .cached,
                    detailNote: nil
                )
            }
            switch await claudeClient.fetch(token: token) {
            case .success(let response):
                writeCache(CachedClaudeResponse(fetchedAt: Date(), response: response), at: configuration.claudeCacheURL)
                return claudeProviderUsage(from: response, planLabel: planLabel, freshness: .live, detailNote: nil)
            case .failure(let err):
                if shouldRefreshClaudeAfterFailure(err) {
                    if let current = creds,
                       let refreshed = await refreshClaudeAuth(current)
                       ?? KeychainCredentialsLoader.reloadClaudeFromKeychain() {
                        creds = refreshed
                        plan = refreshed.plan
                        switch await claudeClient.fetch(token: refreshed.accessToken) {
                        case .success(let response):
                            writeCache(CachedClaudeResponse(fetchedAt: Date(), response: response), at: configuration.claudeCacheURL)
                            return claudeProviderUsage(from: response, planLabel: refreshed.plan.displayName, freshness: .live, detailNote: "token refreshed")
                        case .failure:
                            break
                        }
                    }
                }
                if let cached {
                    let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
                    return claudeProviderUsage(
                        from: cached.response,
                        planLabel: planLabel,
                        freshness: .stale,
                        staleAgeMinutes: age,
                        detailNote: describeClaude(err)
                    )
                }
                return localClaudeEstimate(
                    plan: plan,
                    planLabel: planLabel,
                    freshness: .offline,
                    detailNote: describeClaude(err)
                )
            }
        }
        // Token unreadable, but a prior API response may still be on disk.
        if let cached {
            let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
            return claudeProviderUsage(
                from: cached.response,
                planLabel: planLabel,
                freshness: .stale,
                staleAgeMinutes: age,
                detailNote: "no keychain auth"
            )
        }
        // No keychain creds. If the user has never run Claude Code locally either,
        // treat the provider as unconfigured so the UI hides it.
        let claudeProjects = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        if !FileManager.default.fileExists(atPath: claudeProjects.path) {
            return signedOutUsage(providerName: "Claude")
        }
        return localClaudeEstimate(
            plan: plan,
            planLabel: planLabel,
            freshness: .estimate,
            detailNote: "no keychain auth"
        )
    }

    private func refreshClaudeAuth(_ creds: ClaudeCredentials) async -> ClaudeCredentials? {
        guard creds.canRefresh else { return nil }
        guard let refreshed = try? await ClaudeTokenRefresher.refresh(creds) else { return nil }
        return refreshed
    }

    private func signedOutUsage(providerName: String) -> ProviderUsage {
        ProviderUsage(
            planLabel: providerName,
            freshness: .signedOut,
            note: UsageDisplay.signInMessage(for: providerName),
            isConfigured: false
        )
    }

    private func describeClaude(_ err: OAuthUsageClient.FetchError) -> String {
        switch err {
        case .http(let code): return "HTTP \(code)"
        case .decode: return "decode error"
        case .network: return "network error"
        }
    }

    private func shouldRefreshClaudeAfterFailure(_ err: OAuthUsageClient.FetchError) -> Bool {
        switch err {
        case .http(let code):
            return code == 401 || code == 403
        case .decode(_), .network(_):
            return false
        }
    }

    private func claudeProviderUsage(
        from r: OAuthUsageClient.Response,
        planLabel: String,
        freshness: UsageFreshness,
        staleAgeMinutes: Int? = nil,
        detailNote: String? = nil
    ) -> ProviderUsage {
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
        return ProviderUsage(
            fiveHour: fiveHour,
            weekly: weekly
        ).withMetadata(
            planLabel: planLabel,
            freshness: freshness,
            staleAgeMinutes: staleAgeMinutes,
            detailNote: detailNote
        )
    }

    private func localClaudeEstimate(
        plan: ClaudePlan,
        planLabel: String,
        freshness: UsageFreshness,
        detailNote: String? = nil
    ) -> ProviderUsage {
        let limits = configuration.claudeOverrideLimits ?? PlanLimits.defaults(for: plan)
        let usage = ClaudeUsageReader(plan: plan, limits: limits).read()
        return usage.withMetadata(
            planLabel: planLabel,
            freshness: freshness,
            detailNote: detailNote
        )
    }

    // MARK: - Codex

    private func readCodex() async -> ProviderUsage {
        // Read the on-disk cache once and reuse it for the freshness check and
        // the stale fallback below.
        let cached: CachedCodexResponse? = readCache(at: configuration.codexCacheURL)

        if var auth = CodexAuth.loadDefault() {
            let planLabel = auth.planType.map { "Codex \($0)" } ?? "Codex"

            if let cached,
               Date().timeIntervalSince(cached.fetchedAt) < configuration.minOAuthInterval {
                return codexProviderUsage(
                    from: cached.response,
                    fetchedAt: cached.fetchedAt,
                    planLabel: cached.planLabel ?? planLabel,
                    freshness: .cached,
                    detailNote: nil
                )
            }

            if auth.needsRefresh(),
               let refreshed = await refreshCodexAuth(auth) {
                auth = refreshed
            }

            switch await codexClient.fetch(auth: auth) {
            case .success(let response):
                let now = Date()
                writeCache(CachedCodexResponse(fetchedAt: now, response: response, planLabel: planLabel), at: configuration.codexCacheURL)
                return codexProviderUsage(from: response, fetchedAt: now, planLabel: planLabel, freshness: .live, detailNote: nil)
            case .failure(let err):
                if shouldRefreshAfterCodexFailure(err),
                   let refreshed = await refreshCodexAuth(auth),
                   refreshed.accessToken != auth.accessToken {
                    switch await codexClient.fetch(auth: refreshed) {
                    case .success(let response):
                        let now = Date()
                        writeCache(CachedCodexResponse(fetchedAt: now, response: response, planLabel: planLabel), at: configuration.codexCacheURL)
                        return codexProviderUsage(from: response, fetchedAt: now, planLabel: planLabel, freshness: .live, detailNote: "token refreshed")
                    case .failure:
                        break
                    }
                }
                if let cached {
                    let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
                    return codexProviderUsage(
                        from: cached.response,
                        fetchedAt: cached.fetchedAt,
                        planLabel: cached.planLabel ?? planLabel,
                        freshness: .stale,
                        staleAgeMinutes: age,
                        detailNote: describeCodex(err)
                    )
                }
                // Last resort — JSONL snapshot from the most recent session.
                let fallback = CodexUsageReader().read()
                return fallback.withMetadata(
                    planLabel: planLabel,
                    freshness: .offline,
                    detailNote: describeCodex(err)
                )
            }
        }
        // No auth.json. If the user has never run Codex locally either,
        // treat the provider as unconfigured so the UI hides it.
        let codexSessions = CodexAuth.codexHome().appendingPathComponent("sessions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: codexSessions.path) {
            return signedOutUsage(providerName: "Codex")
        }
        let fallback = CodexUsageReader().read()
        return fallback.withMetadata(
            planLabel: "Codex",
            freshness: .estimate,
            detailNote: "no auth"
        )
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

    private func codexProviderUsage(
        from r: CodexUsageClient.Response,
        fetchedAt: Date,
        planLabel: String,
        freshness: UsageFreshness,
        staleAgeMinutes: Int? = nil,
        detailNote: String? = nil
    ) -> ProviderUsage {
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
        let resolvedPlan = r.plan_type.map { "Codex \($0)" } ?? planLabel
        return ProviderUsage(fiveHour: fiveHour, weekly: weekly).withMetadata(
            planLabel: resolvedPlan,
            freshness: freshness,
            staleAgeMinutes: staleAgeMinutes,
            detailNote: detailNote
        )
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
        // Read the on-disk cache once and reuse it for the freshness check and
        // the stale fallback below.
        let cached: CachedCursorResponse? = readCache(at: configuration.cursorCacheURL)

        guard var credentials = CursorCredentialsLoader.load() else {
            return signedOutUsage(providerName: "Cursor")
        }

        if let cached,
           Date().timeIntervalSince(cached.fetchedAt) < configuration.minOAuthInterval {
            return cursorProviderUsage(from: cached, freshness: .cached, detailNote: nil)
        }

        if credentials.needsRefresh(),
           let refreshed = await refreshCursorAuth(credentials) {
            credentials = refreshed
        }

        switch await fetchCursorUsage(credentials: credentials) {
        case .success(let fresh):
            writeCache(fresh, at: configuration.cursorCacheURL)
            return cursorProviderUsage(from: fresh, freshness: .live, detailNote: nil)
        case .failure(let err):
            if shouldRefreshAfterCursorFailure(err),
               let refreshed = await refreshCursorAuth(credentials),
               refreshed.accessToken != credentials.accessToken {
                switch await fetchCursorUsage(credentials: refreshed) {
                case .success(let fresh):
                    writeCache(fresh, at: configuration.cursorCacheURL)
                    return cursorProviderUsage(from: fresh, freshness: .live, detailNote: "token refreshed")
                case .failure:
                    break
                }
            }
            if let cached {
                let age = Int(Date().timeIntervalSince(cached.fetchedAt) / 60)
                return cursorProviderUsage(
                    from: cached,
                    freshness: .stale,
                    staleAgeMinutes: age,
                    detailNote: describeCursor(err)
                )
            }
            switch await fetchCursorLegacyUsage(credentials: credentials) {
            case .success(let usage):
                return usage
            case .failure:
                return ProviderUsage(isConfigured: true).withMetadata(
                    planLabel: "Cursor",
                    freshness: .offline,
                    detailNote: describeCursor(err)
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
                membershipType: credentials.membershipType
            ) else {
                return .failure(.emptyUsage)
            }
            return .success(usage.withMetadata(
                planLabel: usage.planLabel ?? "Cursor",
                freshness: .live,
                detailNote: "legacy API"
            ))
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

    private func cursorProviderUsage(
        from cached: CachedCursorResponse,
        freshness: UsageFreshness,
        staleAgeMinutes: Int? = nil,
        detailNote: String? = nil
    ) -> ProviderUsage {
        if let mapped = CursorUsageMapper.providerUsage(
            from: cached.usage,
            planName: cached.planName,
            membershipType: cached.membershipType
        ) {
            return mapped.withMetadata(
                planLabel: mapped.planLabel ?? "Cursor",
                freshness: freshness,
                staleAgeMinutes: staleAgeMinutes,
                detailNote: detailNote
            )
        }
        if let legacy = cached.legacyUsage,
           let mapped = CursorUsageMapper.providerUsage(
               from: legacy,
               membershipType: cached.membershipType
           ) {
            return mapped.withMetadata(
                planLabel: mapped.planLabel ?? "Cursor",
                freshness: freshness,
                staleAgeMinutes: staleAgeMinutes,
                detailNote: detailNote
            )
        }
        return ProviderUsage(isConfigured: true).withMetadata(
            planLabel: "Cursor",
            freshness: freshness,
            staleAgeMinutes: staleAgeMinutes,
            detailNote: detailNote
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
        /// Plan label derived from auth at fetch time, cached so cache-fresh
        /// ticks don't need to re-read auth.json just to recover it. Optional so
        /// caches written by older builds still decode.
        let planLabel: String?
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
