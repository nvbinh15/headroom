import Foundation
import HeadroomKit

@main
struct HeadroomCLI {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        let jsonMode = args.contains("--json")

        let state = await Refresher().snapshot()

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
            renderProvider("Claude", state.claude)
            rendered = true
        }
        if state.codex.isConfigured {
            if rendered { print("") }
            renderProvider("Codex", state.codex)
            rendered = true
        }
        if !rendered {
            print("No providers signed in. Sign in to Claude Code or Codex CLI to see usage here.")
        }
    }

    static func formatPct(_ frac: Double?) -> String {
        guard let frac else { return "  ?% " }
        return String(format: "%4.1f%%", frac * 100)
    }

    static func formatReset(_ date: Date?) -> String {
        date?.headroomCountdown() ?? "—"
    }

    static func renderProvider(_ name: String, _ usage: ProviderUsage) {
        print("\(name)")
        if let n = usage.note { print("  \(n)") }
        if let w = usage.fiveHour {
            let used = w.tokensUsed.map { " (\($0.formatted()) tok)" } ?? ""
            print("  5h     \(formatPct(w.fraction))\(used)  resets in \(formatReset(w.resetsAt))")
        } else {
            print("  5h     n/a")
        }
        if let w = usage.weekly {
            let used = w.tokensUsed.map { " (\($0.formatted()) tok)" } ?? ""
            print("  weekly \(formatPct(w.fraction))\(used)  resets in \(formatReset(w.resetsAt))")
        } else {
            print("  weekly n/a")
        }
    }
}
