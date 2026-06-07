import Foundation

public enum UsageFreshness: String, Codable, Sendable {
    case live
    case cached
    case stale
    case estimate
    case offline
    case signedOut
}

public enum UsageFractionStyle: Sendable {
    case used
    case remaining
}

public enum UsageDisplay {
    public static func statusNote(for usage: ProviderUsage) -> String {
        if usage.freshness == .signedOut || !usage.isConfigured {
            return "Not signed in"
        }

        let plan = usage.planLabel ?? "Usage"
        switch usage.freshness {
        case .live, .none:
            return "\(plan) · just updated"
        case .cached:
            return "\(plan) · cached"
        case .stale:
            if let age = usage.staleAgeMinutes {
                return "\(plan) · may be outdated · \(formatStaleAge(age))"
            }
            return "\(plan) · may be outdated"
        case .estimate:
            return "\(plan) · estimated locally"
        case .offline:
            return "\(plan) · offline"
        case .signedOut:
            return "Not signed in"
        }
    }

    public static func isStale(_ usage: ProviderUsage) -> Bool {
        usage.freshness == .stale || usage.freshness == .estimate || usage.freshness == .offline
    }

    public static func formatFraction(_ fraction: Double?, style: UsageFractionStyle) -> String {
        guard let fraction else { return "—" }
        let value = style == .remaining ? (1 - fraction) : fraction
        return String(format: "%.0f%%", value * 100)
    }

    public static func displayFraction(_ fraction: Double?, style: UsageFractionStyle) -> Double? {
        guard let fraction else { return nil }
        return style == .remaining ? max(0, min(1, 1 - fraction)) : fraction
    }

    public static func warningFraction(in usage: ProviderUsage) -> Double? {
        let values = [usage.fiveHour?.fraction, usage.weekly?.fraction].compactMap { $0 }
        return values.max()
    }

    public static func menuBarLine(
        name: String,
        usage: ProviderUsage,
        style: UsageFractionStyle
    ) -> String {
        let primary = usage.fiveHour?.fraction
        let secondary = usage.weekly?.fraction
        let primaryText = formatFraction(primary, style: style)
        if let secondary {
            return "\(name) \(primaryText)/\(formatFraction(secondary, style: style))"
        }
        return "\(name) \(primaryText)"
    }

    public static func menuBarSummary(
        state: UsageState,
        showClaude: Bool,
        showCodex: Bool,
        showCursor: Bool,
        style: UsageFractionStyle
    ) -> String {
        var lines: [String] = []
        if state.claude.isConfigured, showClaude {
            lines.append(menuBarLine(name: "Claude", usage: state.claude, style: style))
        }
        if state.codex.isConfigured, showCodex {
            lines.append(menuBarLine(name: "Codex", usage: state.codex, style: style))
        }
        if state.cursor.isConfigured, showCursor {
            lines.append(menuBarLine(name: "Cursor", usage: state.cursor, style: style))
        }
        return lines.joined(separator: "\n")
    }

    public static func signInMessage(for providerName: String) -> String {
        providerSignInHint(name: providerName)
    }

    public static func settingsStatusText(for usage: ProviderUsage) -> String {
        if let detail = usage.detailNote, !detail.isEmpty {
            let base = usage.note ?? "—"
            return "\(base) · \(detail)"
        }
        return usage.note ?? "—"
    }

    public static func providerSignInHint(name: String) -> String {
        switch name {
        case "Claude": return "Run Claude Code and sign in"
        case "Codex": return "Run Codex CLI and sign in"
        case "Cursor": return "Open Cursor IDE and sign in"
        default: return "Sign in to see usage"
        }
    }

    private static func formatStaleAge(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}

public extension ProviderUsage {
    func withMetadata(
        planLabel: String,
        freshness: UsageFreshness,
        staleAgeMinutes: Int? = nil,
        detailNote: String? = nil
    ) -> ProviderUsage {
        var copy = self
        copy.planLabel = planLabel
        copy.freshness = freshness
        copy.staleAgeMinutes = staleAgeMinutes
        copy.detailNote = detailNote
        copy.note = UsageDisplay.statusNote(for: copy)
        return copy
    }
}
