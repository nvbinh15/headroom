import Foundation
import HeadroomKit

@main
struct HeadroomCLI {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        let jsonMode = args.contains("--json")
        let showRemaining = savedShowRemainingPercent()

        let state = await Refresher().snapshot(showRemainingPercent: showRemaining)
        let style: UsageFractionStyle = state.showRemainingPercent ? .remaining : .used

        if jsonMode {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(state),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            } else {
                FileHandle.standardError.write(Data("failed to encode state\n".utf8))
                exit(1)
            }
            return
        }

        var rendered = false
        if state.claude.isConfigured {
            renderProvider("Claude", state.claude, style: style)
            rendered = true
        }
        if state.codex.isConfigured {
            if rendered { print("") }
            renderProvider("Codex", state.codex, style: style)
            rendered = true
        }
        if state.cursor.isConfigured {
            if rendered { print("") }
            renderProvider("Cursor", state.cursor, style: style)
            rendered = true
        }
        if !rendered {
            print("No providers signed in. Sign in to Claude Code, Codex CLI, or Cursor to see usage here.")
        }
    }

    static func formatPct(_ frac: Double?, style: UsageFractionStyle) -> String {
        guard let frac else { return "  ?% " }
        let value = style == .remaining ? (1 - frac) : frac
        return String(format: "%4.1f%%", value * 100)
    }

    static func formatReset(_ date: Date?) -> String {
        date?.headroomCountdown() ?? "—"
    }

    static func renderProvider(_ name: String, _ usage: ProviderUsage, style: UsageFractionStyle) {
        print("\(name)")
        if let n = usage.note { print("  \(n)") }
        let primaryLabel = usage.fiveHourLabel ?? "5h"
        let secondaryLabel = usage.weeklyLabel ?? "weekly"
        if let w = usage.fiveHour {
            let used = w.tokensUsed.map { " (\($0.formatted()) tok)" } ?? ""
            print("  \(primaryLabel.padding(toLength: 6, withPad: " ", startingAt: 0)) \(formatPct(w.fraction, style: style))\(used)  resets in \(formatReset(w.resetsAt))")
        } else {
            print("  \(primaryLabel.padding(toLength: 6, withPad: " ", startingAt: 0)) n/a")
        }
        if let w = usage.weekly {
            let used = w.tokensUsed.map { " (\($0.formatted()) tok)" } ?? ""
            print("  \(secondaryLabel.padding(toLength: 6, withPad: " ", startingAt: 0)) \(formatPct(w.fraction, style: style))\(used)  resets in \(formatReset(w.resetsAt))")
        } else if usage.fiveHour != nil {
            print("  \(secondaryLabel.padding(toLength: 6, withPad: " ", startingAt: 0)) n/a")
        }
    }

    private static func savedShowRemainingPercent() -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = support.appendingPathComponent("Headroom/state.json")
        guard let data = try? Data(contentsOf: url) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(UsageState.self, from: data) else { return false }
        return state.showRemainingPercent
    }
}
