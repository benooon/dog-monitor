import AVKit
import DogMonitorCore
import SwiftUI

/// One moment: its clip (or snapshot), when and where it happened, and "was this right?".
struct EventDetailView: View {
    let model: TimelineModel
    let eventId: UUID

    var body: some View {
        if let event = model.feed.event(id: eventId) {
            EventDetailList(model: model, event: event)
        } else {
            ContentUnavailableView("This moment is gone", systemImage: "clock.badge.xmark")
        }
    }
}

private struct EventDetailList: View {
    let model: TimelineModel
    let event: EventDTO

    var body: some View {
        List {
            if event.hasMedia {
                Section {
                    EventMediaView(model: model, event: event)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                if let name = model.cameraName(for: event) {
                    LabeledContent("Camera") { Text(verbatim: name) }
                }
                LabeledContent("Started") {
                    Text(event.startedAt, format: .dateTime.weekday().hour().minute())
                }
                if let duration = event.duration, duration >= 1 {
                    LabeledContent("Lasted") {
                        Text(Duration.seconds(duration), format: .units(
                            allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2
                        ))
                    }
                }
            }
            if event.type.acceptsFeedback {
                Section {
                    FeedbackButtons(selection: event.feedback) { verdict in
                        Task { await model.toggleFeedback(verdict, for: event) }
                    }
                } header: {
                    Text("Was this right?")
                } footer: {
                    if model.feedbackFailed {
                        Text("Your answer wasn't saved. Check your connection and try again.")
                    } else {
                        Text("Your answers help the camera learn what's worth telling you.")
                    }
                }
            }
        }
        .navigationTitle(event.type.notificationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Two side-by-side choices; tapping the chosen one again clears it.
private struct FeedbackButtons: View {
    let selection: DogEvent.Feedback?
    let choose: (DogEvent.Feedback) -> Void

    /// HIG minimum tap target.
    private static var minimumTapHeight: CGFloat { 44 }

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            choice(.correct, title: "Yes", symbol: "hand.thumbsup")
            choice(.wrong, title: "No", symbol: "hand.thumbsdown")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .sensoryFeedback(.selection, trigger: selection)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func choice(_ verdict: DogEvent.Feedback, title: LocalizedStringKey, symbol: String) -> some View {
        let isSelected = selection == verdict
        return Button {
            choose(verdict)
        } label: {
            Label(title, systemImage: isSelected ? symbol + ".fill" : symbol)
                .frame(maxWidth: .infinity, minHeight: Self.minimumTapHeight)
        }
        .tint(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Loads short-lived media URLs and shows the clip, or the snapshot when there is no clip.
private struct EventMediaView: View {
    let model: TimelineModel
    let event: EventDTO

    private enum Phase {
        case loading
        case clip(AVPlayer)
        case snapshot(URL)
        case unavailable
        case failed
    }

    @State private var phase: Phase = .loading

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            switch phase {
            case .loading:
                ProgressView()
            case .clip(let player):
                VideoPlayer(player: player)
            case .snapshot(let url):
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .accessibilityLabel(Text("Snapshot from the camera"))
            case .unavailable:
                message("Clips aren't set up yet.", systemImage: "film")
            case .failed:
                VStack(spacing: DS.Spacing.s) {
                    message("Couldn't load the clip.", systemImage: "exclamationmark.triangle")
                    Button("Try again") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        .task(id: event.id) { await load() }
        .onDisappear {
            if case .clip(let player) = phase { player.pause() }
        }
    }

    private func message(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(DS.Spacing.l)
    }

    private func load() async {
        phase = .loading
        do {
            let media = try await model.media(for: event)
            if let clip = media.clipUrl {
                phase = .clip(AVPlayer(url: clip))
            } else if let snapshot = media.snapshotUrl {
                phase = .snapshot(snapshot)
            } else {
                phase = .unavailable
            }
        } catch let error as APIError where error.code == "storage_not_configured" {
            phase = .unavailable
        } catch {
            phase = .failed
        }
    }
}

#Preview {
    let model = TimelineModel.preview
    NavigationStack {
        EventDetailView(model: model, eventId: model.feed.events[1].id)
    }
}

#Preview("Hebrew (RTL)") {
    let model = TimelineModel.preview
    NavigationStack {
        EventDetailView(model: model, eventId: model.feed.events[1].id)
    }
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    let model = TimelineModel.preview
    NavigationStack {
        EventDetailView(model: model, eventId: model.feed.events[1].id)
    }
    .preferredColorScheme(.dark)
}

#Preview("Gone") {
    NavigationStack {
        EventDetailView(model: .preview, eventId: UUID())
    }
}
