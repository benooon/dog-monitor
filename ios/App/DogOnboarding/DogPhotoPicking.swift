import DogMonitorCore
import PhotosUI
import SwiftUI
import UIKit

/// Picking the dog's photo: from the library (`PhotosPicker` bound to `item`) or the camera
/// (`takesPhoto`), then a round crop the owner can move and zoom before it is used.
private struct DogPhotoPicking: ViewModifier {
    @Binding var item: PhotosPickerItem?
    @Binding var takesPhoto: Bool
    let onCropped: (UIImage) -> Void

    @State private var captured: UIImage?
    @State private var cropRequest: CropRequest?

    func body(content: Content) -> some View {
        content
            .onChange(of: item) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        cropRequest = CropRequest(image: image)
                    }
                    item = nil
                }
            }
            .fullScreenCover(isPresented: $takesPhoto, onDismiss: {
                // Show the crop once the camera is fully gone, so the two never overlap.
                if let captured {
                    cropRequest = CropRequest(image: captured)
                    self.captured = nil
                }
            }) {
                CameraPicker { image in captured = image }
                    .ignoresSafeArea()
            }
            .sheet(item: $cropRequest) { request in
                PhotoCropView(image: request.image, onUse: onCropped)
            }
    }
}

private struct CropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
}

extension View {
    /// Library or camera photo → round crop → `onCropped` with a square, upload-sized image.
    func dogPhotoPicking(
        item: Binding<PhotosPickerItem?>,
        takesPhoto: Binding<Bool>,
        onCropped: @escaping (UIImage) -> Void
    ) -> some View {
        modifier(DogPhotoPicking(item: item, takesPhoto: takesPhoto, onCropped: onCropped))
    }
}

/// The system camera, for one still photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    /// False on devices without a camera (and in the simulator): hide "Take a photo" there.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, dismiss: { dismiss() })
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

/// Move and zoom the photo inside the round avatar frame, like the system's contact photo crop.
struct PhotoCropView: View {
    let image: UIImage
    let onUse: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var crop: PhotoCrop?
    @State private var dragStart: CGSize?
    @State private var zoomStart: Double?

    /// How much one VoiceOver swipe zooms.
    private static let zoomStep = 0.25

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let side = max(min(proxy.size.width, proxy.size.height) - DS.Spacing.xl * 2, 1)
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let crop {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: crop.displayWidth, height: crop.displayHeight)
                            .offset(x: crop.offsetX, y: crop.offsetY)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                            .overlay { mask(side: side) }
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag.simultaneously(with: magnify))
                // The photo is not mirrored in right-to-left languages, and neither are its gestures.
                .environment(\.layoutDirection, .leftToRight)
                .onChange(of: side, initial: true) { _, newSide in
                    let size = image.size
                    var fresh = PhotoCrop(imageWidth: size.width, imageHeight: size.height, viewport: newSide)
                    if let crop {
                        fresh.set(zoom: crop.zoom, offsetX: 0, offsetY: 0)
                    }
                    crop = fresh
                }
                .accessibilityElement()
                .accessibilityLabel(Text("Photo"))
                .accessibilityHint(Text("Swipe up or down to zoom."))
                .accessibilityAdjustableAction { direction in
                    guard var current = crop else { return }
                    let step = direction == .increment ? Self.zoomStep : -Self.zoomStep
                    current.set(zoom: current.zoom + step, offsetX: current.offsetX, offsetY: current.offsetY)
                    crop = current
                }
            }
            .navigationTitle("Move and scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use photo") {
                        if let crop {
                            onUse(DogPhoto.crop(image, rect: crop.cropRect, side: DogPhoto.uploadSide))
                        }
                        dismiss()
                    }
                    .disabled(crop == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Darkens everything outside the circle and outlines it.
    private func mask(side: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.55))
                .reverseMask { Circle().frame(width: side, height: side) }
            Circle()
                .strokeBorder(.white.opacity(0.8), lineWidth: 1)
                .frame(width: side, height: side)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard var current = crop else { return }
                let start = dragStart ?? CGSize(width: current.offsetX, height: current.offsetY)
                dragStart = start
                current.set(
                    zoom: current.zoom,
                    offsetX: start.width + value.translation.width,
                    offsetY: start.height + value.translation.height
                )
                crop = current
            }
            .onEnded { _ in dragStart = nil }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard var current = crop else { return }
                let start = zoomStart ?? current.zoom
                zoomStart = start
                current.set(zoom: start * value.magnification, offsetX: current.offsetX, offsetY: current.offsetY)
                crop = current
            }
            .onEnded { _ in zoomStart = nil }
    }
}

private extension View {
    /// Shows this view everywhere except where `mask` is drawn.
    func reverseMask<Hole: View>(@ViewBuilder _ hole: () -> Hole) -> some View {
        let holeView = hole()
        return mask {
            Rectangle()
                .overlay { holeView.blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}

#Preview {
    PhotoCropView(image: DogPhotoStore.samplePortrait()) { _ in }
}

#Preview("Hebrew (RTL)") {
    PhotoCropView(image: DogPhotoStore.samplePortrait()) { _ in }
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    PhotoCropView(image: DogPhotoStore.samplePortrait()) { _ in }
        .preferredColorScheme(.dark)
}
