import Foundation

/// Anthropic plan tiers as exposed in the OAuth credential blob's `rateLimitTier` field.
public enum ClaudePlan: String, Codable, CaseIterable, Sendable {
    case pro = "default_claude_pro"
    case max5x = "default_claude_max_5x"
    case max20x = "default_claude_max_20x"
    case team = "default_claude_team"
    case apiKey = "api_key"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .pro: return "Pro"
        case .max5x: return "Max 5×"
        case .max20x: return "Max 20×"
        case .team: return "Team"
        case .apiKey: return "API key"
        case .unknown: return "Unknown plan"
        }
    }
}

/// Token ceilings per rolling window. Anthropic doesn't publish exact numbers; these are
/// community-derived estimates that the user can override in Settings.
public struct PlanLimits: Codable, Sendable, Equatable {
    public var fiveHourTokens: Int?
    public var weeklyTokens: Int?

    public init(fiveHourTokens: Int?, weeklyTokens: Int?) {
        self.fiveHourTokens = fiveHourTokens
        self.weeklyTokens = weeklyTokens
    }

    public static func defaults(for plan: ClaudePlan) -> PlanLimits {
        switch plan {
        case .pro:
            return PlanLimits(fiveHourTokens: 44_000, weeklyTokens: nil)
        case .max5x:
            return PlanLimits(fiveHourTokens: 220_000, weeklyTokens: 1_900_000)
        case .max20x:
            return PlanLimits(fiveHourTokens: 880_000, weeklyTokens: 7_700_000)
        case .team:
            return PlanLimits(fiveHourTokens: 220_000, weeklyTokens: 1_900_000)
        case .apiKey, .unknown:
            return PlanLimits(fiveHourTokens: nil, weeklyTokens: nil)
        }
    }
}
