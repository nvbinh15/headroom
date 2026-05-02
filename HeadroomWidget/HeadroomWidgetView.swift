import SwiftUI
import WidgetKit
import HeadroomKit

struct HeadroomWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall: SmallWidgetView(state: entry.state)
        default:           MediumWidgetView(state: entry.state)
        }
    }
}

private struct SmallWidgetView: View {
    let state: UsageState

    var body: some View {
        if !state.claude.isConfigured && !state.codex.isConfigured {
            EmptyState()
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    if state.claude.isConfigured {
                        RingView(label: "C", fraction: state.claude.fiveHour?.fraction)
                    }
                    if state.codex.isConfigured {
                        RingView(label: "X", fraction: state.codex.fiveHour?.fraction)
                    }
                }
                HStack(spacing: 8) {
                    if state.claude.isConfigured {
                        MiniBar(label: "C·wk", fraction: state.claude.weekly?.fraction)
                    }
                    if state.codex.isConfigured {
                        MiniBar(label: "X·wk", fraction: state.codex.weekly?.fraction)
                    }
                }
            }
            .padding(8)
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Headroom").font(.caption.bold())
            Text("Sign in to Claude Code or Codex CLI")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }
}

private struct MediumWidgetView: View {
    let state: UsageState

    var body: some View {
        if !state.claude.isConfigured && !state.codex.isConfigured {
            EmptyState()
        } else {
            VStack(spacing: 8) {
                if state.claude.isConfigured {
                    ProviderRow(name: "Claude", usage: state.claude)
                }
                if state.claude.isConfigured && state.codex.isConfigured {
                    Divider()
                }
                if state.codex.isConfigured {
                    ProviderRow(name: "Codex",  usage: state.codex)
                }
            }
            .padding(12)
        }
    }

    struct ProviderRow: View {
        let name: String
        let usage: ProviderUsage

        var body: some View {
            HStack(spacing: 14) {
                Text(name)
                    .font(.subheadline.bold())
                    .frame(width: 56, alignment: .leading)
                WindowCell(title: "5h",     window: usage.fiveHour)
                WindowCell(title: "Weekly", window: usage.weekly)
            }
        }
    }

    struct WindowCell: View {
        let title: String
        let window: WindowUsage?

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(percentText)
                        .font(.caption2.monospacedDigit().bold())
                }
                ProgressView(value: window?.fraction ?? 0).tint(tint)
                Text(resetText).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }

        private var tint: Color {
            guard let f = window?.fraction else { return .secondary }
            if f >= 0.9 { return .red }
            if f >= 0.7 { return .orange }
            return .accentColor
        }
        private var percentText: String {
            window?.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        }
        private var resetText: String {
            guard let date = window?.resetsAt else { return " " }
            return "in \(date.headroomCountdown())"
        }
    }
}

private struct RingView: View {
    let label: String
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction ?? 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(label).font(.caption2.bold())
                Text(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.caption2.monospacedDigit())
            }
        }
    }

    private var tint: Color {
        guard let f = fraction else { return .secondary }
        if f >= 0.9 { return .red }
        if f >= 0.7 { return .orange }
        return .accentColor
    }
}

private struct MiniBar: View {
    let label: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.caption2.monospacedDigit())
            }
            ProgressView(value: fraction ?? 0).tint(.accentColor)
        }
    }
}
