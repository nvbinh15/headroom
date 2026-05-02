import SwiftUI
import HeadroomKit

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
                    Button("Open data folder") {
                        controller.openDataFolder()
                    }
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
        }
        .formStyle(.grouped)
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
