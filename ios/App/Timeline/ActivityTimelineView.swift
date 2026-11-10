import DogMonitorCore
import SwiftUI

/// Everything the cameras noticed, newest first, grouped by day. Filters by camera and type;
/// tap a moment to see its clip and say whether the detection was right.
/// (Named to stay clear of SwiftUI's `TimelineView`.)
struct ActivityTimelineView: View {
    @State private var model: TimelineModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar

    init(model: TimelineModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Activity")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .navigationDestination(for: UUID.self) { eventId in
                    EventDetailView(model: model, eventId: eventId)
                }
        }
        .task {
            if model.phase != .ready { await model.refresh() }
        }
        .sensoryFeedback(.error, trigger: model.feedbackFailed) { _, failed in failed }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load activity", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") {
                    Task { await model.refresh() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready:
            if model.feed.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isFiltered {
            ContentUnavailableView {
                Label("Nothing here", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing matches these filters yet.")
            } actions: {
                Button("Show everything") { model.clearFilters() }
            }
        } else {
            ContentUnavailableView {
                Label("No activity yet", systemImage: "clock")
            } description: {
                Text("Barking, visits to the door and other moments show up here.")
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.feed.days(calendar: calendar)) { day in
                Section {
                    ForEach(day.events) { event in
                        NavigationLink(value: event.id) {
                            TimelineRow(event: event, cameraName: model.cameraName(for: event))
                        }
                    }
                } header: {
                    DayHeader(day: day.day)
                }
            }
            if model.feed.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .task(id: model.feed.nextCursor) { await model.loadMore() }
            }
        }
        .refreshable { await model.refresh() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                if model.cameras.count > 1 {
                    Picker("Camera", selection: $model.cameraId) {
                        Text("All cameras").tag(UUID?.none)
                        ForEach(model.cameras) { camera in
                            Text(verbatim: camera.name).tag(Optional(camera.id))
                        }
                    }
                }
                Section("Show") {
                    ForEach(EventType.timelineFilters, id: \.self) { type in
                        Toggle(isOn: typeBinding(type)) {
                            Label(type.notificationTitle, systemImage: type.notificationSymbol)
                        }
                    }
                }
                if model.isFiltered {
                    Button("Show everything", systemImage: "xmark.circle") { model.clearFilters() }
                }
            } label: {
                Label("Filter", systemImage: model.isFiltered
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }
            .accessibilityIdentifier("timeline-filter")
        }
    }

    private func typeBinding(_ type: EventType) -> Binding<Bool> {
        Binding {
            model.types.contains(type)
        } set: { isOn in
            if isOn {
                model.types.insert(type)
            } else {
                model.types.remove(type)
            }
        }
    }
}

/// "Today", "Yesterday", or the weekday and date.
private struct DayHeader: View {
    let day: Date
    @Environment(\.calendar) private var calendar

    var body: some View {
        if calendar.isDateInToday(day) {
            Text("Today")
        } else if calendar.isDateInYesterday(day) {
            Text("Yesterday")
        } else {
            Text(day, format: .dateTime.weekday(.wide).month().day())
        }
    }
}

#Preview {
    ActivityTimelineView(model: .preview)
}

#Preview("Hebrew (RTL)") {
    ActivityTimelineView(model: .preview)
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    ActivityTimelineView(model: .preview)
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    ActivityTimelineView(model: TimelineModel(api: .timelinePreview, cameras: [], loaded: []))
}
