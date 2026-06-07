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

    private var fractionStyle: UsageFractionStyle {
        state.showRemainingPercent ? .remaining : .used
    }

    var body: some View {
        if !state.claude.isConfigured && !state.codex.isConfigured && !state.cursor.isConfigured {
            EmptyState()
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    if state.claude.isConfigured {
                        RingView(
                            label: "C",
                            fraction: state.claude.fiveHour?.fraction,
                            isStale: UsageDisplay.isStale(state.claude),
                            fractionStyle: fractionStyle
                        )
                    }
                    if state.codex.isConfigured {
                        RingView(
                            label: "X",
                            fraction: state.codex.fiveHour?.fraction,
                            isStale: UsageDisplay.isStale(state.codex),
                            fractionStyle: fractionStyle
                        )
                    }
                    if state.cursor.isConfigured {
                        RingView(
                            label: "Cu",
                            fraction: state.cursor.fiveHour?.fraction,
                            isStale: UsageDisplay.isStale(state.cursor),
                            fractionStyle: fractionStyle
                        )
                    }
                }
                HStack(spacing: 8) {
                    if state.claude.isConfigured, state.claude.weekly != nil {
                        MiniBar(
                            label: shortLabel(state.claude.weeklyLabel ?? "Weekly"),
                            fraction: state.claude.weekly?.fraction,
                            fractionStyle: fractionStyle
                        )
                    }
                    if state.codex.isConfigured, state.codex.weekly != nil {
                        MiniBar(
                            label: shortLabel(state.codex.weeklyLabel ?? "Weekly"),
                            fraction: state.codex.weekly?.fraction,
                            fractionStyle: fractionStyle
                        )
                    }
                    if state.cursor.isConfigured, state.cursor.weekly != nil {
                        MiniBar(
                            label: shortLabel(state.cursor.weeklyLabel ?? "API"),
                            fraction: state.cursor.weekly?.fraction,
                            fractionStyle: fractionStyle
                        )
                    }
                }
            }
            .padding(8)
        }
    }

    private func shortLabel(_ label: String) -> String {
        let prefix: String
        if label == "Weekly" { prefix = "wk" }
        else if label == "API" { prefix = "API" }
        else { prefix = String(label.prefix(3)) }
        return prefix
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Headroom").font(.caption.bold())
            Text("Sign in to Claude Code, Codex CLI, or Cursor")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(8)
    }
}

private struct MediumWidgetView: View {
    let state: UsageState

    private var fractionStyle: UsageFractionStyle {
        state.showRemainingPercent ? .remaining : .used
    }

    var body: some View {
        if !state.claude.isConfigured && !state.codex.isConfigured && !state.cursor.isConfigured {
            EmptyState()
        } else {
            VStack(spacing: 8) {
                if state.claude.isConfigured {
                    ProviderRow(name: "Claude", usage: state.claude, fractionStyle: fractionStyle)
                }
                if state.claude.isConfigured && (state.codex.isConfigured || state.cursor.isConfigured) {
                    Divider()
                }
                if state.codex.isConfigured {
                    ProviderRow(name: "Codex", usage: state.codex, fractionStyle: fractionStyle)
                }
                if state.codex.isConfigured && state.cursor.isConfigured {
                    Divider()
                }
                if state.cursor.isConfigured {
                    ProviderRow(name: "Cursor", usage: state.cursor, fractionStyle: fractionStyle)
                }
            }
            .padding(12)
        }
    }

    struct ProviderRow: View {
        let name: String
        let usage: ProviderUsage
        let fractionStyle: UsageFractionStyle

        var body: some View {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.subheadline.bold())
                    if UsageDisplay.isStale(usage) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 56, alignment: .leading)
                if usage.fiveHour != nil {
                    WindowCell(
                        title: usage.fiveHourLabel ?? "5h",
                        window: usage.fiveHour,
                        fractionStyle: fractionStyle
                    )
                }
                if usage.weekly != nil {
                    WindowCell(
                        title: usage.weeklyLabel ?? "Weekly",
                        window: usage.weekly,
                        fractionStyle: fractionStyle
                    )
                }
            }
        }
    }

    struct WindowCell: View {
        let title: String
        let window: WindowUsage?
        let fractionStyle: UsageFractionStyle

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
            UsageDisplay.formatFraction(window?.fraction, style: fractionStyle)
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
    var isStale: Bool = false
    var fractionStyle: UsageFractionStyle = .used

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction ?? 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(label).font(.caption2.bold())
                Text(UsageDisplay.formatFraction(fraction, style: fractionStyle))
                    .font(.caption2.monospacedDigit())
            }
            if isStale {
                Circle()
                    .strokeBorder(.orange.opacity(0.8), lineWidth: 1)
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
    var fractionStyle: UsageFractionStyle = .used

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text(UsageDisplay.formatFraction(fraction, style: fractionStyle))
                    .font(.caption2.monospacedDigit())
            }
            ProgressView(value: fraction ?? 0).tint(.accentColor)
        }
    }
}
