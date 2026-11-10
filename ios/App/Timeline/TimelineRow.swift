import DogMonitorCore
import SwiftUI

/// One moment in the timeline: what happened, on which camera, when, and the viewer's verdict.
struct TimelineRow: View {
    let event: EventDTO
    let cameraName: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                EventSymbol(type: event.type)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(event.type.notificationTitle)
                    .font(.body)
                if let details {
                    Text(verbatim: details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let feedback = event.feedback {
                Image(systemName: feedback.symbol)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(feedback.accessibilityLabel)
            }
            Text(event.startedAt, format: .dateTime.hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "Living room · 3 min"; parts we don't know are left out.
    private var details: String? {
        let parts = [cameraName, event.duration.flatMap(Self.formatted(duration:))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatted(duration: TimeInterval) -> String? {
        guard duration >= 1 else { return nil }
        return Duration.seconds(duration).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)
        )
    }
}

/// The event's symbol in a tinted circle.
struct EventSymbol: View {
    let type: EventType
    @ScaledMetric(relativeTo: .body) private var size = 32

    var body: some View {
        Image(systemName: type.notificationSymbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(type.timelineTint)
            .frame(width: size, height: size)
            .background(type.timelineTint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

extension EventType {
    /// Orange for moments that need a look, green when the dog settles, gray for the camera.
    var timelineTint: Color {
        switch self {
        case .prolongedBarking, .whining, .forbiddenZone, .atDoor: .orange
        case .calmedDown: .green
        case .notVisible, .dailySummary: .accentColor
        case .cameraOffline, .lowBattery, .overheating: .secondary
        }
    }
}

extension DogEvent.Feedback {
    var symbol: String {
        switch self {
        case .correct: "hand.thumbsup.fill"
        case .wrong: "hand.thumbsdown.fill"
        }
    }

    var accessibilityLabel: Text {
        switch self {
        case .correct: Text("Marked right")
        case .wrong: Text("Marked wrong")
        }
    }
}
