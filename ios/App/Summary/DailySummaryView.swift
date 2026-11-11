import Charts
import DogMonitorCore
import SwiftUI

/// How the dog's day went on one camera: rest, barks and activity, with hourly and weekly charts.
struct DailySummaryView: View {
    @State private var model: DailySummaryModel
    let dogName: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar

    init(model: DailySummaryModel, dogName: String?) {
        _model = State(initialValue: model)
        self.dogName = dogName
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .refreshable { await model.load(calendar: calendar) }
        }
        .task {
            if model.phase != .ready { await model.load(calendar: calendar) }
        }
    }

    /// "Rex's day" when we know the dog's name.
    private var title: Text {
        if let dogName {
            Text("\(dogName)'s day")
        } else {
            Text("Daily summary")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .failed:
            ContentUnavailableView {
                Label("Couldn't load the summary", systemImage: "chart.bar")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") {
                    Task { await model.load(calendar: calendar) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .ready:
            let insights = model.insights
            if insights.day == nil {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "chart.bar")
                } description: {
                    Text("Summaries appear once a camera has been on for a while.")
                }
            } else {
                summaryList(insights)
            }
        }
    }

    private func summaryList(_ insights: DailySummaryInsights) -> some View {
        List {
            if let summary = model.selectedSummary, summary.hasReel == true {
                HighlightReelSection(model: model, summary: summary, dogName: dogName)
            }
            Section {
                SummaryHeadline(insights: insights)
            } header: {
                if let day = insights.day {
                    DayTitle(dateKey: day.date)
                }
            }
            if insights.isEmpty {
                Section {
                    Text("The camera didn't see much on this day.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Activity by hour") {
                    HourlyActivityChart(points: insights.hourly, dateKey: insights.day?.date ?? "")
                }
                if insights.week.count > 1 {
                    Section("Barks this week") {
                        WeeklyBarksChart(points: insights.week)
                    }
                }
                if !insights.stateShares.isEmpty {
                    Section("Time by state") {
                        ForEach(insights.stateShares) { share in
                            LabeledContent {
                                Text(minutes: share.minutes)
                            } label: {
                                if let label = share.state.label {
                                    Text(label)
                                }
                            }
                        }
                    }
                }
            }
        }
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
                        ForEach(model.cameras) { camera in
                            Text(verbatim: camera.name).tag(Optional(camera.id))
                        }
                    }
                }
                if model.dates.count > 1 {
                    Picker("Day", selection: $model.selectedDate) {
                        ForEach(model.dates, id: \.self) { date in
                            DayTitle(dateKey: date).tag(date == model.dates.first ? String?.none : date)
                        }
                    }
                }
            } label: {
                Label("Choose a day", systemImage: "calendar")
            }
            .disabled(model.cameras.count < 2 && model.dates.count < 2)
        }
    }
}

/// Rest, barks and activity for the day, each compared with the day before when we have it.
private struct SummaryHeadline: View {
    let insights: DailySummaryInsights
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                rested
                barks
                active
            }
            .padding(.vertical, DS.Spacing.xs)
        } else {
            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.l, verticalSpacing: DS.Spacing.m) {
                GridRow {
                    rested
                    barks
                }
                GridRow {
                    active
                }
            }
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    private var rested: SummaryStat {
        SummaryStat(
            title: "Rested",
            systemImage: "moon.zzz",
            value: Text(minutes: insights.day?.restMinutes ?? 0),
            change: insights.restChange.map(restChangeText)
        )
    }

    private var barks: SummaryStat {
        SummaryStat(
            title: "Barks",
            systemImage: "waveform",
            value: Text(insights.day?.barkCount ?? 0, format: .number),
            change: insights.barkChange.map(barkChangeText)
        )
    }

    private var active: SummaryStat {
        SummaryStat(title: "Active", systemImage: "figure.walk", value: Text(minutes: insights.activeMinutes), change: nil)
    }
}

private struct SummaryStat: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: Text
    let change: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            value
                .font(.title2.weight(.light))
                .monospacedDigit()
                .contentTransition(.numericText())
            if let change {
                change
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private func barkChangeText(_ delta: Int) -> Text {
    if delta > 0 {
        Text("\(delta) more than yesterday")
    } else if delta < 0 {
        Text("\(-delta) fewer than yesterday")
    } else {
        Text("Same as yesterday")
    }
}

private func restChangeText(_ delta: Int) -> Text {
    let amount = Text(minutes: abs(delta))
    if delta > 0 {
        return Text("\(amount) more than yesterday")
    } else if delta < 0 {
        return Text("\(amount) less than yesterday")
    } else {
        return Text("Same as yesterday")
    }
}

/// Minutes with motion in each hour of the day.
private struct HourlyActivityChart: View {
    let points: [DailySummaryInsights.HourPoint]
    let dateKey: String
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    /// Tall enough to read 24 bars; grows with Dynamic Type so axis labels keep room.
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 160

    var body: some View {
        let start = DailySummaryInsights.date(from: dateKey, calendar: calendar) ?? calendar.startOfDay(for: .now)
        Chart(points) { point in
            let hour = calendar.date(byAdding: .hour, value: point.hour, to: start) ?? start
            BarMark(
                x: .value("Hour", hour, unit: .hour),
                y: .value("Minutes", point.activeMinutes)
            )
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel(Text(hour, format: .dateTime.hour()))
            .accessibilityValue(Text(minutes: point.activeMinutes))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().locale(locale))
            }
        }
        .chartYScale(domain: 0...60)
        .chartYAxis {
            AxisMarks(values: [0, 30, 60])
        }
        .frame(minHeight: chartHeight)
        .padding(.vertical, DS.Spacing.s)
    }
}

/// Barks per day over the last week.
private struct WeeklyBarksChart: View {
    let points: [DailySummaryInsights.DayPoint]
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 140
    /// Earlier days recede so today's bar stands out.
    private static var earlierDayOpacity: Double { 0.35 }

    var body: some View {
        let latest = points.last?.id
        let dated = points.compactMap { point in
            DailySummaryInsights.date(from: point.date, calendar: calendar).map { DatedDay(day: $0, point: point) }
        }
        Chart(dated) { item in
            BarMark(
                x: .value("Day", item.day, unit: .day),
                y: .value("Barks", item.point.barkCount)
            )
            .foregroundStyle(item.point.id == latest ? Color.accentColor : Color.accentColor.opacity(Self.earlierDayOpacity))
            .accessibilityLabel(Text(item.day, format: .dateTime.weekday(.wide).day().month()))
            .accessibilityValue(Text(item.point.barkCount, format: .number))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow).locale(locale), centered: true)
            }
        }
        .frame(minHeight: chartHeight)
        .padding(.vertical, DS.Spacing.s)
    }
}

private struct DatedDay: Identifiable {
    let day: Date
    let point: DailySummaryInsights.DayPoint
    var id: String { point.id }
}

/// "Today", "Yesterday" or the date, for a "YYYY-MM-DD" key.
private struct DayTitle: View {
    let dateKey: String
    @Environment(\.calendar) private var calendar
    /// Tall enough to read 24 bars; grows with Dynamic Type so axis labels keep room.
    @ScaledMetric(relativeTo: .caption) private var chartHeight: CGFloat = 160

    var body: some View {
        if let date = DailySummaryInsights.date(from: dateKey, calendar: calendar) {
            if calendar.isDateInToday(date) {
                Text("Today")
            } else if calendar.isDateInYesterday(date) {
                Text("Yesterday")
            } else {
                Text(date, format: .dateTime.weekday(.wide).day().month())
            }
        } else {
            Text(verbatim: dateKey)
        }
    }
}

private extension Text {
    /// "1 hr, 20 min" for a number of minutes, formatted at render time so it follows the
    /// environment's locale (Hebrew screens get Hebrew units).
    init(minutes: Int) {
        self.init(Duration.seconds(minutes * 60), format: .units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

#Preview {
    DailySummaryView(model: .preview, dogName: "Rex")
}

#Preview("Hebrew (RTL)") {
    DailySummaryView(model: .preview, dogName: "רקס")
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    DailySummaryView(model: .preview, dogName: nil)
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    DailySummaryView(model: DailySummaryModel(api: .offline, cameras: [], loaded: []), dogName: "Rex")
}

private extension DogMonitorAPI {
    /// A client previews never call (they pass loaded data).
    static var offline: DogMonitorAPI {
        DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!)
    }
}

extension DailySummaryModel {
    /// A week of sample days for one camera, no network.
    static var preview: DailySummaryModel {
        let camera = UUID()
        let calendar = Calendar.current
        let days: [DailySummaryDTO] = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: .now) ?? .now
            var activity = Array(repeating: 0, count: 24)
            for hour in 7..<22 { activity[hour] = (hour * 7 + offset * 5) % 25 }
            return DailySummaryDTO(
                cameraId: camera,
                date: DailySummaryAccumulator.dateKey(date, calendar: calendar),
                restMinutes: 420 - offset * 15,
                barkCount: 6 + (offset * 5) % 11,
                activityByHour: activity,
                stateMinutes: ["resting": 420 - offset * 15, "restless": 70, "barking": 9, "atDoor": 12],
                isFinal: offset > 0
            )
        }
        return DailySummaryModel(api: .offline, cameras: [], cameraId: camera, loaded: days)
    }
}
