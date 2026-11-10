import DogMonitorCore
import SwiftUI
import WidgetKit

/// Home and Lock Screen widget with the dog's last known state. The app writes the state into
/// the shared app group; the widget never claims it's live and says when it last heard.
struct DogStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: DogStatusStore.widgetKind, provider: DogStatusProvider()) { entry in
            DogStatusWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Dog status")
        .description("What your dog is up to, from your camera.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
    }
}

struct DogStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: DogStatusSnapshot?
}

struct DogStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> DogStatusEntry {
        DogStatusEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (DogStatusEntry) -> Void) {
        let snapshot = DogStatusSnapshot.featured(in: DogStatusStore.load())
        completion(DogStatusEntry(date: .now, snapshot: snapshot ?? (context.isPreview ? .placeholder : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DogStatusEntry>) -> Void) {
        let snapshot = DogStatusSnapshot.featured(in: DogStatusStore.load())
        let now = Date.now
        var entries = [DogStatusEntry(date: now, snapshot: snapshot)]
        // One more entry when the snapshot goes stale, so the widget stops showing it as current.
        if let snapshot, !snapshot.isStale(at: now) {
            let staleAt = snapshot.updatedAt.addingTimeInterval(DogStatusSnapshot.staleAfter + 1)
            entries.append(DogStatusEntry(date: staleAt, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct DogStatusWidgetView: View {
    let entry: DogStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "pawprint")
                    .font(.title2)
                    .accessibilityHidden(true)
                if family != .accessoryCircular {
                    Text("Open Dog Monitor to see your dog here.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ snapshot: DogStatusSnapshot) -> some View {
        let state = snapshot.displayState(at: entry.date)
        switch family {
        case .accessoryCircular:
            Image(systemName: state.symbol)
                .font(.title2)
                .accessibilityLabel(statusText(snapshot, state: state))
                .widgetAccentable()
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(snapshot.title, systemImage: state.symbol)
                    .font(.headline)
                    .widgetAccentable()
                statusText(snapshot, state: state)
                    .font(.caption)
                updatedText(snapshot)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: state.symbol)
                    .font(.title)
                    .foregroundStyle(state.isAlerting ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(verbatim: snapshot.title)
                    .font(.headline)
                    .lineLimit(1)
                statusText(snapshot, state: state)
                    .font(.subheadline)
                    .lineLimit(2)
                updatedText(snapshot)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func statusText(_ snapshot: DogStatusSnapshot, state: DogState) -> Text {
        if !snapshot.online { return Text("Camera offline") }
        if snapshot.isStale(at: entry.date) { return Text("Open the app for an update") }
        if let label = state.label { return Text(label) }
        return Text("Watching")
    }

    private func updatedText(_ snapshot: DogStatusSnapshot) -> Text {
        Text(snapshot.updatedAt, style: .relative)
    }
}

extension DogStatusSnapshot {
    /// "Rex", or the camera's name before the household has a dog.
    var title: String { dogName ?? cameraName }

    static var placeholder: DogStatusSnapshot {
        DogStatusSnapshot(cameraId: UUID(), cameraName: "Living room", dogName: "Rex", state: .resting, online: true, updatedAt: .now)
    }
}

#Preview("Small", as: .systemSmall) {
    DogStatusWidget()
} timeline: {
    DogStatusEntry(date: .now, snapshot: .placeholder)
    DogStatusEntry(date: .now, snapshot: nil)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
    DogStatusWidget()
} timeline: {
    DogStatusEntry(date: .now, snapshot: .placeholder)
}
