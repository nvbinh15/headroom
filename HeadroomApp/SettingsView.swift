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
                Picker("Density", selection: $controller.menuBarDensity) {
                    ForEach(MenuBarDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: controller.menuBarDensity) { _, _ in
                    DisplayPreferences.markDensityExplicitlySet()
                }

                Toggle("Claude", isOn: $controller.menuBarShowClaude)
                    .disabled(!controller.state.claude.isConfigured)
                Toggle("Codex", isOn: $controller.menuBarShowCodex)
                    .disabled(!controller.state.codex.isConfigured)
                Toggle("Cursor", isOn: $controller.menuBarShowCursor)
                    .disabled(!controller.state.cursor.isConfigured)
            } header: {
                Text("Providers")
            } footer: {
                Text(menuBarFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Toggle("Show remaining %", isOn: $controller.showRemainingPercent)
                Toggle("Low headroom warnings", isOn: $controller.lowHeadroomWarnings)
            } header: {
                Text("Display")
            } footer: {
                Text("Remaining % shows headroom instead of used. Warnings notify once when any window crosses 70% or 90% used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Refresh now") {
                    HStack(spacing: 8) {
                        ForEach(RefreshController.Provider.allCases) { provider in
                            Button(provider.rawValue) {
                                Task { await controller.forceRefresh(provider) }
                            }
                            .buttonStyle(HoverBackgroundButtonStyle())
                            .disabled(controller.isRefreshing || !controller.isConfigured(provider))
                        }
                    }
                }
                LabeledContent("Local files") {
                    Button("Open data folder") {
                        controller.openDataFolder()
                    }
                    .buttonStyle(HoverBackgroundButtonStyle())
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Refresh now fetches live usage for that provider, skipping the 5-minute cache. Claude also re-reads its login from Claude Code or the Claude desktop app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Claude") {
                    Text(UsageDisplay.settingsStatusText(for: controller.state.claude))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Codex") {
                    Text(UsageDisplay.settingsStatusText(for: controller.state.codex))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Cursor") {
                    Text(UsageDisplay.settingsStatusText(for: controller.state.cursor))
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
                    Text("Headroom is not affiliated with Anthropic, OpenAI, or Cursor. It reads the local credentials those tools already store on this machine, then queries each service's usage endpoint to show your remaining budget.")

                    DataFlowGroup(
                        title: "Reads from disk",
                        items: [
                            "~/.codex/auth.json — Codex OAuth bearer + account ID",
                            "~/.codex/sessions/**/*.jsonl — used as a fallback when the API is unreachable",
                            "~/.claude/.credentials.json — Claude OAuth bearer when Claude Code stores it there",
                            "~/.claude/projects/**/*.jsonl — used as a fallback when the API is unreachable",
                            "~/Library/Application Support/Claude/config.json — Claude desktop app's encrypted OAuth bearer, used read-only when Claude Code's login is missing or expired",
                            "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb — Cursor OAuth bearer (encrypted by Cursor 3.x, used read-only)",
                            "~/Library/Application Support/Headroom/claude-credentials.json — Headroom's local Claude OAuth copy after the first successful read"
                        ]
                    )
                    DataFlowGroup(
                        title: "Reads from macOS keychain",
                        items: [
                            "“Claude Code-credentials” — Claude OAuth bearer written by Claude Code (read once, then cached on disk)",
                            "“Claude Safe Storage” / “Cursor Safe Storage” — keys to decrypt the desktop apps' tokens above (macOS asks once)",
                            "“cursor-access-token” / “cursor-refresh-token” — Cursor CLI OAuth when present"
                        ]
                    )
                    DataFlowGroup(
                        title: "Sends over the network",
                        items: [
                            "GET api.anthropic.com/api/oauth/usage",
                            "GET chatgpt.com/backend-api/wham/usage",
                            "POST api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage and /GetPlanInfo",
                            "GET api2.cursor.sh/auth/usage (enterprise fallback)",
                            "POST platform.claude.com, auth.openai.com, api2.cursor.sh /oauth/token — only to renew an expired CLI login"
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
        .frame(width: 480, height: 580)
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

    private var menuBarFooter: String {
        if controller.menuBarDensity == .hidden {
            return "Shows only the Headroom icon; it turns orange or red when a visible provider is running low. Provider toggles also apply to the popover, widget, and warnings."
        }
        return "\(controller.menuBarDensity.detail). Choose which signed-in providers appear in Headroom."
    }
}
