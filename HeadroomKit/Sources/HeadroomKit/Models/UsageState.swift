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
    /// Free-form note: plan tier, "from API", "estimate", "no recent sessions", etc.
    public var note: String?

    public init(fiveHour: WindowUsage? = nil, weekly: WindowUsage? = nil, note: String? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.note = note
    }
}

public struct UsageState: Codable, Sendable, Equatable {
    public var claude: ProviderUsage
    public var codex: ProviderUsage
    public var lastUpdated: Date

    public init(claude: ProviderUsage, codex: ProviderUsage, lastUpdated: Date = Date()) {
        self.claude = claude
        self.codex = codex
        self.lastUpdated = lastUpdated
    }

    public static let empty = UsageState(
        claude: ProviderUsage(),
        codex: ProviderUsage(),
        lastUpdated: .distantPast
    )
}
