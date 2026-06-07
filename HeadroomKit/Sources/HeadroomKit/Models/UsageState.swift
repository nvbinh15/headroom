import Foundation

/// One window's worth of usage (e.g. 5 hour or weekly).
public struct WindowUsage: Codable, Sendable, Equatable {
    /// 0...1 fraction used. `nil` if unknown / not applicable for this plan.
    public var fraction: Double?
    /// Tokens consumed in the window (Claude only; Codex doesn't expose raw tokens).
    public var tokensUsed: Int?
    /// Plan ceiling for this window in tokens (Claude only).
    public var tokensLimit: Int?
    /// When the window resets. `nil` if unknown.
    public var resetsAt: Date?
    /// Window length in minutes (300 for 5h, 10080 for weekly).
    public var windowMinutes: Int

    public init(
        fraction: Double? = nil,
        tokensUsed: Int? = nil,
        tokensLimit: Int? = nil,
        resetsAt: Date? = nil,
        windowMinutes: Int
    ) {
        self.fraction = fraction
        self.tokensUsed = tokensUsed
        self.tokensLimit = tokensLimit
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

public struct ProviderUsage: Codable, Sendable, Equatable {
    public var fiveHour: WindowUsage?
    public var weekly: WindowUsage?
    /// Override for the primary window label in UI/CLI (default "5h").
    public var fiveHourLabel: String?
    /// Override for the secondary window label in UI/CLI (default "Weekly").
    public var weeklyLabel: String?
    /// Free-form note: plan tier, "from API", "estimate", "no recent sessions", etc.
    public var note: String?
    /// False when the provider has no auth and no local data on disk. UI surfaces
    /// hide unconfigured providers entirely instead of rendering empty rows.
    public var isConfigured: Bool

    public init(
        fiveHour: WindowUsage? = nil,
        weekly: WindowUsage? = nil,
        fiveHourLabel: String? = nil,
        weeklyLabel: String? = nil,
        note: String? = nil,
        isConfigured: Bool = true
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fiveHourLabel = fiveHourLabel
        self.weeklyLabel = weeklyLabel
        self.note = note
        self.isConfigured = isConfigured
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fiveHour = try c.decodeIfPresent(WindowUsage.self, forKey: .fiveHour)
        self.weekly = try c.decodeIfPresent(WindowUsage.self, forKey: .weekly)
        self.fiveHourLabel = try c.decodeIfPresent(String.self, forKey: .fiveHourLabel)
        self.weeklyLabel = try c.decodeIfPresent(String.self, forKey: .weeklyLabel)
        self.note = try c.decodeIfPresent(String.self, forKey: .note)
        // Default to true for state.json files written by older builds.
        self.isConfigured = try c.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? true
    }
}

public struct UsageState: Codable, Sendable, Equatable {
    public var claude: ProviderUsage
    public var codex: ProviderUsage
    public var cursor: ProviderUsage
    public var lastUpdated: Date

    public init(
        claude: ProviderUsage,
        codex: ProviderUsage,
        cursor: ProviderUsage = ProviderUsage(isConfigured: false),
        lastUpdated: Date = Date()
    ) {
        self.claude = claude
        self.codex = codex
        self.cursor = cursor
        self.lastUpdated = lastUpdated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claude = try c.decode(ProviderUsage.self, forKey: .claude)
        self.codex = try c.decode(ProviderUsage.self, forKey: .codex)
        self.cursor = try c.decodeIfPresent(ProviderUsage.self, forKey: .cursor)
            ?? ProviderUsage(isConfigured: false)
        self.lastUpdated = try c.decode(Date.self, forKey: .lastUpdated)
    }

    public static let empty = UsageState(
        claude: ProviderUsage(),
        codex: ProviderUsage(),
        cursor: ProviderUsage(isConfigured: false),
        lastUpdated: .distantPast
    )
}
