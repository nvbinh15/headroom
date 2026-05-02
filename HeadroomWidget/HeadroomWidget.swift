import WidgetKit
import SwiftUI
import HeadroomKit

@main
struct HeadroomWidgetBundle: WidgetBundle {
    var body: some Widget {
        HeadroomWidget()
    }
}

struct HeadroomWidget: Widget {
    let kind = "HeadroomWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            HeadroomWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Headroom")
        .description("5-hour and weekly usage for Claude Code and Codex CLI.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let state: UsageState
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), state: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), state: SharedState.read() ?? .empty))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let state = SharedState.read() ?? .empty
        let now = Date()
        let entry = UsageEntry(date: now, state: state)
        // Reload at the next reset (or 5 min from now, whichever sooner).
        let nextReset = [
            state.claude.fiveHour?.resetsAt,
            state.claude.weekly?.resetsAt,
            state.codex.fiveHour?.resetsAt,
            state.codex.weekly?.resetsAt
        ].compactMap { $0 }.filter { $0 > now }.min() ?? now.addingTimeInterval(15 * 60)
        let nextReload = min(nextReset, now.addingTimeInterval(5 * 60))
        completion(Timeline(entries: [entry], policy: .after(nextReload)))
    }
}

enum SharedState {
    static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Headroom/state.json")
    }()

    static func read() -> UsageState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageState.self, from: data)
    }
}
