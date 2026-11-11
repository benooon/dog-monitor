import AVKit
import DogMonitorCore
import SwiftUI

/// The day's highlight reel (Premium) at the top of the daily summary, with a Share button.
/// The shared video ends on a small "Dog Monitor" card, added by the camera.
struct HighlightReelSection: View {
    let model: DailySummaryModel
    let summary: DailySummaryDTO
    let dogName: String?
    /// Visible height of the list, so the player can be capped at ~60% of it. Zero while unknown.
    var containerHeight: CGFloat = 0

    private enum Phase {
        case loading
        case ready(URL, AVPlayer)
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var rowWidth: CGFloat = 0

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
        // Sized from the row width (9:16, capped by the screen height); `containerRelativeFrame`
        // doesn't resolve to the screen inside a List row, which left the video letterboxed.
        let size = ReelPlayerLayout.size(
            availableWidth: Double(rowWidth),
            containerHeight: Double(containerHeight)
        )
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
        .frame(width: CGFloat(size.width), height: CGFloat(size.height))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
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
