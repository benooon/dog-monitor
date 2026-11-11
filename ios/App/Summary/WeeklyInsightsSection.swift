import DogMonitorCore
import SwiftUI

/// "This week" in the daily summary (Premium): what changed since last week, and the 30-day
/// report to share with the vet. Free households see one line about what Premium adds.
struct WeeklyInsightsSection: View {
    let model: DailySummaryModel
    let dogName: String?
    @Environment(\.calendar) private var calendar

    var body: some View {
        switch model.insightsUnlocked {
        case true?:
            unlocked
        case false?:
            locked
        case nil:
            EmptyView() // plan unknown (offline): say nothing rather than guess
        }
    }

    private var unlocked: some View {
        let insights = model.weeklyInsights(calendar: calendar)
        let report = model.vetReport
        return Section {
            if insights.trends.isEmpty {
                Group {
                    if insights.canCompare {
                        Text("A steady week, close to the one before.")
                    } else {
                        Text("Comparisons start once there are two weeks of summaries.")
                    }
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(insights.trends, id: \.self) { trend in
                    TrendRow(trend: trend, dogName: dogName)
                }
            }
            if !report.isEmpty {
                VetReportShareRow(report: report, dogName: dogName, cameraName: model.cameraName)
            }
        } header: {
            Text("This week")
        } footer: {
            if !report.isEmpty {
                Text("The last 30 days as a PDF: rest, barking, whining and time at the door.")
            }
        }
    }

    private var locked: some View {
        Section {
            Label {
                if let dogName {
                    Text("Compare \(dogName)'s weeks")
                } else {
                    Text("Compare weeks")
                }
            } icon: {
                Image(systemName: "chart.line.uptrend.xyaxis")
            }
            .foregroundStyle(.secondary)
        } footer: {
            Text("Premium compares each week with the last and makes a report for your vet.")
        }
    }
}

private struct TrendRow: View {
    let trend: WeeklyInsights.Trend
    let dogName: String?
    @Environment(\.calendar) private var calendar

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
        }
    }

    private var symbol: String {
        switch trend {
        case .barking: "waveform"
        case .sofa: "sofa"
        case .rest: "moon.zzz"
        case .busiestHour: "clock"
        }
    }

    private var text: Text {
        switch trend {
        case .barking(let percent):
            let amount = Text(Double(abs(percent)) / 100, format: .percent)
            switch (dogName, percent < 0) {
            case (let name?, true): return Text("\(name) barked \(amount) less than last week")
            case (let name?, false): return Text("\(name) barked \(amount) more than last week")
            case (nil, true): return Text("\(amount) less barking than last week")
            case (nil, false): return Text("\(amount) more barking than last week")
            }
        case .sofa(let visits, let allAfterHour):
            if visits == 1 {
                return Text("On the sofa once")
            } else if let allAfterHour {
                return Text("On the sofa \(visits) times, all after \(hour(allAfterHour))")
            } else {
                return Text("On the sofa \(visits) times")
            }
        case .rest(let minutes):
            let amount = Text(minutes: abs(minutes))
            return minutes > 0
                ? Text("\(amount) more rest a day than last week")
                : Text("\(amount) less rest a day than last week")
        case .busiestHour(let value):
            return Text("Most active around \(hour(value))")
        }
    }

    /// "2 PM" / "14:00" for a local hour, in the screen's locale.
    private func hour(_ value: Int) -> Text {
        let date = calendar.date(bySettingHour: value, minute: 0, second: 0, of: .now) ?? .now
        return Text(date, format: .dateTime.hour())
    }
}

/// Renders the vet report to a PDF when the section appears, then offers it to share.
private struct VetReportShareRow: View {
    let report: VetReport
    let dogName: String?
    let cameraName: String?
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.calendar) private var calendar
    @State private var file: URL?

    var body: some View {
        Group {
            if let file {
                ShareLink(item: file) {
                    Label("Share with your vet", systemImage: "doc.text")
                }
                .accessibilityIdentifier("vet-report-share")
            } else {
                Label("Share with your vet", systemImage: "doc.text")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: report) {
            file = try? VetReportPDF.make(
                report: report,
                dogName: dogName,
                cameraName: cameraName,
                locale: locale,
                layoutDirection: layoutDirection,
                calendar: calendar
            )
        }
    }
}

#Preview("This week") {
    List { WeeklyInsightsSection(model: .preview, dogName: "Rex") }
}

#Preview("This week, Hebrew, dark") {
    List { WeeklyInsightsSection(model: .preview, dogName: "רקס") }
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
}
