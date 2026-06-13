import Foundation
import UserNotifications
import HeadroomKit

@MainActor
final class UsageNotifier {
    static let shared = UsageNotifier()

    private var alertedKeys: Set<String> = []

    func evaluate(state: UsageState, enabled: Bool) {
        guard enabled else {
            alertedKeys.removeAll()
            return
        }

        requestPermissionIfNeeded()

        let providers: [(String, ProviderUsage)] = [
            ("Claude", state.claude),
            ("Codex", state.codex),
            ("Cursor", state.cursor)
        ]

        for (name, usage) in providers where usage.isConfigured {
            evaluateProvider(name: name, usage: usage)
        }
    }

    private func evaluateProvider(name: String, usage: ProviderUsage) {
        let windows: [(String, WindowUsage?)] = [
            (usage.fiveHourLabel ?? "Primary", usage.fiveHour),
            (usage.weeklyLabel ?? "Secondary", usage.weekly)
        ]

        for (label, window) in windows {
            guard let fraction = window?.fraction else { continue }
            let thresholds = [90, 70]
            for threshold in thresholds {
                let key = "\(name)-\(label)-\(threshold)"
                if fraction >= Double(threshold) / 100.0 {
                    if !alertedKeys.contains(key) {
                        alertedKeys.insert(key)
                        postNotification(
                            title: "\(name) running low",
                            body: "\(label) window is \(Int((fraction * 100).rounded()))% used."
                        )
                    }
                } else {
                    alertedKeys.remove(key)
                }
            }
        }
    }

    private func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
