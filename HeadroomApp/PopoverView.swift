import SwiftUI
import HeadroomKit

struct PopoverView: View {
    @EnvironmentObject var controller: RefreshController

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

            ProviderRow(name: "Claude", usage: controller.state.claude)
            ProviderRow(name: "Codex",  usage: controller.state.codex)

            HStack {
                Text("Updated \(relativeTimestamp)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings…") {
                    AppDelegate.shared?.openSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var relativeTimestamp: String {
        guard controller.state.lastUpdated != .distantPast else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: controller.state.lastUpdated, relativeTo: Date())
    }
}

struct ProviderRow: View {
    let name: String
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.subheadline.bold())
                Spacer()
                if let note = usage.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            WindowBar(label: "5h",     window: usage.fiveHour)
            WindowBar(label: "Weekly", window: usage.weekly)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct WindowBar: View {
    let label: String
    let window: WindowUsage?

    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 50, alignment: .leading)
            ProgressView(value: window?.fraction ?? 0)
                .tint(tint)
            Text(percentText)
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Text(resetText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
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
        guard let f = window?.fraction else { return "—" }
        return String(format: "%.0f%%", f * 100)
    }

    private var resetText: String {
        guard let date = window?.resetsAt else { return "" }
        let secs = max(0, Int(date.timeIntervalSinceNow))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h\(String(format: "%02d", m))m" }
        return "\(m)m"
    }
}
