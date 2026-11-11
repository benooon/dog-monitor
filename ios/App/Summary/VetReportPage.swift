import DogMonitorCore
import SwiftUI

/// "Share with your vet": the last 30 days on one A4 page, rendered to a PDF.
@MainActor
enum VetReportPDF {
    /// A4 in points.
    static let pageSize = CGSize(width: 595, height: 842)

    static func make(
        report: VetReport,
        dogName: String?,
        cameraName: String?,
        locale: Locale,
        layoutDirection: LayoutDirection,
        calendar: Calendar
    ) throws -> URL {
        let page = VetReportPage(report: report, dogName: dogName, cameraName: cameraName)
            .frame(width: pageSize.width, height: pageSize.height)
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.calendar, calendar)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        renderer.proposedSize = ProposedViewSize(pageSize)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vet-report", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(dogName: dogName, locale: locale)).appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: url)

        var written = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            written = true
        }
        guard written else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// "Rex – last 30 days", without characters a file name can't have.
    private static func fileName(dogName: String?, locale: Locale) -> String {
        let title = if let dogName {
            String(localized: "\(dogName)'s last 30 days", locale: locale)
        } else {
            String(localized: "The last 30 days", locale: locale)
        }
        return title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

/// The printed page. Fixed sizes on purpose: it is paper, not a screen, so it doesn't follow
/// Dynamic Type.
struct VetReportPage: View {
    let report: VetReport
    let dogName: String?
    let cameraName: String?
    @Environment(\.calendar) private var calendar

    private enum Metrics {
        static let margin: CGFloat = 40
        static let titleSize: CGFloat = 20
        static let bodySize: CGFloat = 10
        static let tableSize: CGFloat = 9
        static let rowSpacing: CGFloat = 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            header
            table
            Spacer(minLength: 0)
            Text("Recorded by the Dog Monitor camera. These are the camera's estimates, not a diagnosis.")
                .font(.system(size: Metrics.tableSize))
                .foregroundStyle(.secondary)
        }
        .padding(Metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Group {
                if let dogName {
                    Text("\(dogName)'s last 30 days")
                } else {
                    Text("The last 30 days")
                }
            }
            .font(.system(size: Metrics.titleSize, weight: .semibold))
            if let from = date(report.from), let to = date(report.to) {
                Text("\(Text(from, format: .dateTime.day().month().year())) – \(Text(to, format: .dateTime.day().month().year()))")
                    .font(.system(size: Metrics.bodySize))
            }
            if let cameraName {
                Text("Camera: \(cameraName)")
                    .font(.system(size: Metrics.bodySize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Spacing.m, verticalSpacing: Metrics.rowSpacing) {
            GridRow {
                columnTitle("Date")
                columnTitle("Rested")
                columnTitle("Restless")
                columnTitle("Barks")
                columnTitle("Whining")
                columnTitle("At the door")
                columnTitle("Active")
            }
            Divider()
            ForEach(report.rows) { row in
                tableRow(dayLabel(row.date), row.figures, weight: .regular)
            }
            if let average = report.average {
                Divider()
                tableRow(Text("Daily average"), average, weight: .semibold)
            }
        }
        .monospacedDigit()
    }

    private func columnTitle(_ title: LocalizedStringKey) -> Text {
        Text(title).font(.system(size: Metrics.tableSize, weight: .semibold))
    }

    private func tableRow(_ label: Text, _ figures: VetReport.Figures, weight: Font.Weight) -> some View {
        let font = Font.system(size: Metrics.tableSize, weight: weight)
        return GridRow {
            label.font(font)
            duration(figures.restMinutes).font(font)
            duration(figures.restlessMinutes).font(font)
            Text(figures.barkCount, format: .number).font(font)
            duration(figures.whiningMinutes).font(font)
            duration(figures.atDoorMinutes).font(font)
            duration(figures.activeMinutes).font(font)
        }
    }

    private func dayLabel(_ key: String) -> Text {
        if let day = date(key) {
            Text(day, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
        } else {
            Text(verbatim: key)
        }
    }

    /// "6:40" (hours:minutes) keeps the columns narrow.
    private func duration(_ minutes: Int) -> Text {
        Text(Duration.seconds(minutes * 60), format: .time(pattern: .hourMinute))
    }

    private func date(_ key: String?) -> Date? {
        key.flatMap { DailySummaryInsights.date(from: $0, calendar: calendar) }
    }
}

#Preview("Vet report") {
    VetReportPage(report: DailySummaryModel.preview.vetReport, dogName: "Rex", cameraName: "Living room")
        .frame(width: VetReportPDF.pageSize.width, height: VetReportPDF.pageSize.height)
}

#Preview("Vet report, Hebrew") {
    VetReportPage(report: DailySummaryModel.preview.vetReport, dogName: "רקס", cameraName: "סלון")
        .frame(width: VetReportPDF.pageSize.width, height: VetReportPDF.pageSize.height)
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}
