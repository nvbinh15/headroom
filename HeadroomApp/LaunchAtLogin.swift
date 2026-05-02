import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` so SwiftUI can bind to it. The status is
/// re-read from the system on every property access since users may toggle
/// it externally (System Settings ▸ General ▸ Login Items).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            // The first registration in an unsigned dev build can throw;
            // surface it via Console.app rather than crashing the UI.
            NSLog("LaunchAtLogin error: \(error.localizedDescription)")
        }
    }
}
