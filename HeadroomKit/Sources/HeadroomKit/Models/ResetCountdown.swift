import Foundation

extension Date {
    /// Compact human-readable countdown to this date from `now`. Picks the
    /// largest unit that's non-zero so weekly resets read as "5d 4h" instead
    /// of "124h13m".
    ///
    ///   ≥ 1 day  →  "5d 4h" (or just "5d" when hours are zero)
    ///   ≥ 1 hour →  "3h 23m"
    ///   < 1 hour →  "12m"
    ///   past     →  "now"
    public func headroomCountdown(from now: Date = Date()) -> String {
        let secs = Int(self.timeIntervalSince(now))
        guard secs > 0 else { return "now" }
        let days = secs / 86_400
        let hours = (secs % 86_400) / 3_600
        let minutes = (secs % 3_600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
