import DogMonitorCore
import SwiftUI

/// Draw door, sofa, forbidden and bed zones over a frame from this camera. Tap to add corners, then
/// add the zone. Coordinates are normalized to the frame, the same space the analysis uses.
struct ZoneEditorView: View {
    let model: CameraModeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: CGImage?
    @State private var isLoadingImage = true
    @State private var zones: [CameraZone] = []
    @State private var draft: [NormalizedPoint] = []
    @State private var kind: CameraZone.Kind = .door
    @State private var isSaving = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    canvas
                        .listRowInsets(EdgeInsets())
                    Picker("Zone type", selection: $kind) {
                        ForEach(CameraZone.Kind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            draft.removeLast()
                        }
                        .disabled(draft.isEmpty)
                        Spacer()
                        Button("Add zone", systemImage: "plus") {
                            addDraft()
                        }
                        .disabled(draft.count < 3 || zones.count >= CameraZone.maxZones)
                    }
                    .buttonStyle(.borderless)
                } footer: {
                    Text("Tap the corners of an area, then add it. The dog's position is checked against these zones.")
                }

                if !zones.isEmpty {
                    Section("Zones") {
                        ForEach(zones) { zone in
                            Label {
                                Text(zone.kind.title)
                            } icon: {
                                Image(systemName: zone.kind.symbol)
                                    .foregroundStyle(zone.kind.color)
                            }
                        }
                        .onDelete { zones.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("Zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                    }
                }
            }
            .alert("Zones saved on this phone only", isPresented: $saveFailed) {
                Button("OK") { dismiss() }
            } message: {
                Text("They'll sync the next time the camera starts with a connection.")
            }
            .task {
                zones = model.zones
                image = await model.snapshot()
                isLoadingImage = false
            }
        }
    }

    private var canvas: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        // Reading the size is needed to turn taps into normalized coordinates.
                        GeometryReader { proxy in
                            ZStack {
                                ZoneShapesOverlay(zones: zones, draft: draft, draftKind: kind, size: proxy.size)
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture { location in
                                        guard draft.count < CameraZone.maxPoints, proxy.size.width > 0, proxy.size.height > 0 else { return }
                                        draft.append(NormalizedPoint(x: location.x / proxy.size.width, y: location.y / proxy.size.height))
                                    }
                                    .accessibilityLabel(Text("Camera view. Tap to add a corner."))
                                    .accessibilityAddTraits(.allowsDirectInteraction)
                            }
                        }
                    }
            } else if isLoadingImage {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ContentUnavailableView(
                    "Start the camera to draw zones",
                    systemImage: "video.slash",
                    description: Text("Zones are drawn on what this camera sees.")
                )
            }
        }
        .animation(reduceMotion ? nil : .default, value: draft)
        .sensoryFeedback(.selection, trigger: draft.count)
    }

    private func addDraft() {
        let polygon = ZonePolygon(points: draft)
        guard polygon.isValid else { return }
        zones.append(CameraZone(kind: kind, polygon: polygon))
        draft = []
    }

    private func save() async {
        if draft.count >= 3 { addDraft() }
        isSaving = true
        let uploaded = await model.saveZones(zones)
        isSaving = false
        if uploaded { dismiss() } else { saveFailed = true }
    }
}

/// Draws saved zones and the zone being drawn.
private struct ZoneShapesOverlay: View {
    let zones: [CameraZone]
    let draft: [NormalizedPoint]
    let draftKind: CameraZone.Kind
    let size: CGSize

    var body: some View {
        ZStack {
            ForEach(zones) { zone in
                path(zone.polygon.points, closed: true)
                    .fill(zone.kind.color.opacity(0.3))
                path(zone.polygon.points, closed: true)
                    .stroke(zone.kind.color, lineWidth: 2)
            }
            path(draft, closed: false)
                .stroke(draftKind.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            ForEach(Array(draft.enumerated()), id: \.offset) { _, point in
                Circle()
                    .fill(draftKind.color)
                    .frame(width: 10, height: 10)
                    .position(x: point.x * size.width, y: point.y * size.height)
            }
        }
        .allowsHitTesting(false)
    }

    private func path(_ points: [NormalizedPoint], closed: Bool) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
            }
            if closed { path.closeSubpath() }
        }
    }
}

extension CameraZone.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .door: "Door"
        case .sofa: "Sofa"
        case .forbidden: "Forbidden"
        case .bed: "Bed"
        }
    }

    var symbol: String {
        switch self {
        case .door: "door.left.hand.closed"
        case .sofa: "sofa.fill"
        case .forbidden: "nosign"
        case .bed: "bed.double"
        }
    }

    var color: Color {
        switch self {
        case .door: .blue
        case .sofa: .orange
        case .forbidden: .red
        case .bed: .green
        }
    }
}

#Preview {
    ZoneEditorView(model: CameraModeModel())
}

#Preview("Hebrew (RTL)") {
    ZoneEditorView(model: CameraModeModel())
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    ZoneEditorView(model: CameraModeModel())
        .preferredColorScheme(.dark)
}
