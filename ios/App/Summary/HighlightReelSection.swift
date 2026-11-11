import AVKit
import DogMonitorCore
import SwiftUI

/// The day's highlight reel (Premium) at the top of the daily summary, with a Share button.
/// The shared video ends on a small "Dog Monitor" card, added by the camera.
struct HighlightReelSection: View {
    let model: DailySummaryModel
    let summary: DailySummaryDTO
    let dogName: String?

    private enum Phase {
        case loading
        case ready(URL, AVPlayer)
        case failed
    }

    @State private var phase: Phase = .loading

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                player
                if case .ready(let file, _) = phase {
                    ShareLink(item: file, preview: SharePreview(shareTitle)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("reel-share")
                }
            }
            .padding(.vertical, DS.Spacing.s)
        } header: {
            title
        }
        .task(id: summary.id) { await load() }
        .onDisappear {
            if case .ready(_, let player) = phase { player.pause() }
        }
    }

    /// "Rex's day in 30 seconds" when we know the dog's name.
    private var title: Text {
        if let dogName {
            Text("\(dogName)'s day in 30 seconds")
        } else {
            Text("The day in 30 seconds")
        }
    }

    private var shareTitle: String {
        if let dogName {
            String(localized: "\(dogName)'s day in 30 seconds")
        } else {
            String(localized: "The day in 30 seconds")
        }
    }

    @ViewBuilder
    private var player: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            switch phase {
            case .loading:
                ProgressView()
            case .ready(_, let player):
                VideoPlayer(player: player)
                    .accessibilityLabel(title)
            case .failed:
                VStack(spacing: DS.Spacing.s) {
                    Label("Couldn't load the video.", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(DS.Spacing.l)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { height, _ in height * 0.6 }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }

    private func load() async {
        phase = .loading
        do {
            let file = try await model.reelFile(for: summary)
            phase = .ready(file, AVPlayer(url: file))
        } catch {
            phase = .failed
        }
    }
}
