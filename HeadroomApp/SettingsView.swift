import SwiftUI
import AppKit
import HeadroomKit

private struct DataFlowGroup: View {
    let title: String
    let items: [String]
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.semibold))
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).foregroundStyle(.secondary)
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }
}

private struct HoverBackgroundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBackgroundLabel(configuration: configuration)
    }

    private struct HoverBackgroundLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(background)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var background: Color {
            if configuration.isPressed { return Color.primary.opacity(0.18) }
            if hovering { return Color.primary.opacity(0.12) }
            return Color.primary.opacity(0.06)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var controller: RefreshController
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LaunchAtLogin.setEnabled(newValue)
                        // Re-read in case the system rejected the change
                        // (e.g. ad-hoc signed builds may need approval).
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
            }

            Section {
                LabeledContent("Refresh every") {
                    HStack(spacing: 8) {
                        Slider(value: $controller.refreshIntervalSeconds, in: 30...600, step: 30)
                            .frame(width: 200)
                        Text(intervalLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("Live API endpoints are throttled internally to once per 5 min, regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Reset caches") {
                        Task { await controller.resetCachesAndRefresh() }
                    }
                    .buttonStyle(HoverBackgroundButtonStyle())
                    Button("Open data folder") {
                        controller.openDataFolder()
                    }
                    .buttonStyle(HoverBackgroundButtonStyle())
                    Spacer()
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Reset caches forces a fresh API call. The data folder contains the snapshot the widget reads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Claude") {
                    Text(controller.state.claude.note ?? "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Codex") {
                    Text(controller.state.codex.note ?? "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Updated") {
                    Text(updatedLabel)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Status")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Headroom is not affiliated with Anthropic or OpenAI. It reads the local credentials those tools already store on this machine, then queries each service's usage endpoint to show your remaining budget.")

                    DataFlowGroup(
                        title: "Reads from disk",
                        items: [
                            "~/.codex/auth.json — Codex OAuth bearer + account ID",
                            "~/.codex/sessions/**/*.jsonl — used as a fallback when the API is unreachable",
                            "~/.claude/projects/**/*.jsonl — used as a fallback when the API is unreachable"
                        ]
                    )
                    DataFlowGroup(
                        title: "Reads from macOS keychain",
                        items: [
                            "“Claude Code-credentials” — Claude OAuth bearer written by Claude Code"
                        ]
                    )
                    DataFlowGroup(
                        title: "Sends over the network",
                        items: [
                            "GET api.anthropic.com/api/oauth/usage",
                            "GET chatgpt.com/backend-api/wham/usage"
                        ],
                        footnote: "Authorized with the bearer tokens above. No telemetry, analytics, or other data leaves your machine."
                    )

                    Text("Anthropic's terms (updated February 2026) restrict third-party use of Claude subscription OAuth tokens to Anthropic's own products. Headroom uses them at your discretion; signing or notarization does not change those underlying terms.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)

                HStack {
                    Button("Privacy policy") {
                        if let url = URL(string: "https://nvbinh15.github.io/headroom/privacy.html") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(HoverBackgroundButtonStyle())
                    Spacer()
                }
            } header: {
                Text("Privacy & Data")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)  // let the window's glass show through
        .frame(width: 480, height: 440)
    }

    private var intervalLabel: String {
        let s = Int(controller.refreshIntervalSeconds)
        if s >= 60 { return "\(s / 60) min" }
        return "\(s) s"
    }

    private var updatedLabel: String {
        guard controller.state.lastUpdated != .distantPast else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: controller.state.lastUpdated, relativeTo: Date())
    }
}
