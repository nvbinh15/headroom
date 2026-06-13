import SwiftUI
import HeadroomKit

private struct HoverTextButtonStyle: ButtonStyle {
    var defaultColor: Color = .secondary
    var hoverColor: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        HoverTextLabel(
            configuration: configuration,
            defaultColor: defaultColor,
            hoverColor: hoverColor
        )
    }

    private struct HoverTextLabel: View {
        let configuration: ButtonStyle.Configuration
        let defaultColor: Color
        let hoverColor: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? hoverColor : defaultColor)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var controller: RefreshController

    private var fractionStyle: UsageFractionStyle {
        controller.state.showRemainingPercent ? .remaining : .used
    }

    private var visibleState: UsageState {
        controller.visibleState()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Headroom")
                    .font(.headline)
                Spacer()
                if controller.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await controller.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }

            if visibleState.claude.isConfigured {
                ProviderRow(name: "Claude", usage: visibleState.claude, fractionStyle: fractionStyle)
            }
            if visibleState.codex.isConfigured {
                ProviderRow(name: "Codex", usage: visibleState.codex, fractionStyle: fractionStyle)
            }
            if visibleState.cursor.isConfigured {
                ProviderRow(name: "Cursor", usage: visibleState.cursor, fractionStyle: fractionStyle)
            }
            if !visibleState.claude.isConfigured
                && !visibleState.codex.isConfigured
                && !visibleState.cursor.isConfigured {
                if hasConfiguredProvider {
                    HiddenProvidersView()
                } else {
                    EmptyStateView()
                }
            } else {
                missingProviderHints
            }

            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Updated \(relativeTimestamp(now: context.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Settings") {
                    AppDelegate.shared?.openSettings()
                }
                .buttonStyle(HoverTextButtonStyle())
                .font(.caption)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(HoverTextButtonStyle())
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var hasConfiguredProvider: Bool {
        controller.state.claude.isConfigured
            || controller.state.codex.isConfigured
            || controller.state.cursor.isConfigured
    }

    @ViewBuilder
    private var missingProviderHints: some View {
        let hints = missingProviderHintRows
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hints, id: \.self) { hint in
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var missingProviderHintRows: [String] {
        var rows: [String] = []
        if !controller.state.claude.isConfigured {
            rows.append("Claude — \(UsageDisplay.providerSignInHint(name: "Claude"))")
        }
        if !controller.state.codex.isConfigured {
            rows.append("Codex — \(UsageDisplay.providerSignInHint(name: "Codex"))")
        }
        if !controller.state.cursor.isConfigured {
            rows.append("Cursor — \(UsageDisplay.providerSignInHint(name: "Cursor"))")
        }
        return rows
    }

    private func relativeTimestamp(now: Date) -> String {
        guard controller.state.lastUpdated != .distantPast else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: controller.state.lastUpdated, relativeTo: now)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No providers signed in")
                .font(.subheadline.bold())
            Text("Claude — \(UsageDisplay.providerSignInHint(name: "Claude"))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Codex — \(UsageDisplay.providerSignInHint(name: "Codex"))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Cursor — \(UsageDisplay.providerSignInHint(name: "Cursor"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct HiddenProvidersView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No providers visible")
                .font(.subheadline.bold())
            Text("Enable a provider in Settings to show usage here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ProviderRow: View {
    let name: String
    let usage: ProviderUsage
    var fractionStyle: UsageFractionStyle = .used

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.subheadline.bold())
                if UsageDisplay.isStale(usage) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Data may be outdated")
                }
                Spacer()
                if let note = usage.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if usage.fiveHour != nil {
                WindowBar(label: usage.fiveHourLabel ?? "5h", window: usage.fiveHour, fractionStyle: fractionStyle)
            }
            if usage.weekly != nil {
                WindowBar(label: usage.weeklyLabel ?? "Weekly", window: usage.weekly, fractionStyle: fractionStyle)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct WindowBar: View {
    let label: String
    let window: WindowUsage?
    var fractionStyle: UsageFractionStyle = .used

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 50, alignment: .leading)
            ProgressView(value: window?.fraction ?? 0)
                .tint(tint)
            Text(percentText)
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(resetText(now: context.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 60, alignment: .trailing)
        }
    }

    private var tint: Color {
        guard let frac = window?.fraction else { return .secondary }
        if frac >= 0.9 { return .red }
        if frac >= 0.7 { return .orange }
        return .accentColor
    }

    private var percentText: String {
        UsageDisplay.formatFraction(window?.fraction, style: fractionStyle)
    }

    private func resetText(now: Date) -> String {
        window?.resetsAt?.headroomCountdown(from: now) ?? ""
    }
}
