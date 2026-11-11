import DogMonitorCore
import SwiftUI

/// Scans an invite QR code on the owner's phone only to read the household's live key, for a
/// phone that is already in the household (it joined with the 6-digit code, or the owner made
/// a new key). Nothing is accepted and nothing is sent to the server.
struct LiveKeyScanView: View {
    let onKey: (LiveKey) -> Void
    /// Screenshots set camera access up front, so no permission prompt appears.
    var fixedCameraAccess: Bool?

    @Environment(\.dismiss) private var dismiss
    @State private var cameraAllowed: Bool?
    @State private var scannedWithoutKey = false
    /// Recreates the scanner after a code without a key, since it reports only its first code.
    @State private var attempt = 0

    private static var scannerHeight: CGFloat { 300 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch cameraAllowed {
                    case true?:
                        QRScannerView { scanned in
                            handle(scanned)
                        }
                        .id(attempt)
                        .frame(height: Self.scannerHeight)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel(Text("Scan the invite QR code on the owner's phone."))
                    case false?:
                        Label("Allow camera access in Settings to scan the code.", systemImage: "qrcode.viewfinder")
                            .foregroundStyle(.secondary)
                    case nil:
                        ProgressView()
                    }
                } footer: {
                    Text("On the owner's phone, open Household and tap Invite family or pair a camera. Scanning here only unlocks live view.")
                }

                if scannedWithoutKey {
                    Section {
                        Label {
                            Text("This code can't unlock live view. Ask the owner to update Dog Monitor and open a new invite.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .sensoryFeedback(.error, trigger: attempt)
            .navigationTitle("Unlock live view")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if let fixedCameraAccess {
                    cameraAllowed = fixedCameraAccess
                    return
                }
                cameraAllowed = await CaptureService.requestAccess(for: .video)
            }
        }
    }

    private func handle(_ scanned: String) {
        guard let key = PairingCode.liveKey(in: scanned) else {
            scannedWithoutKey = true
            attempt += 1
            return
        }
        onKey(key)
        dismiss()
    }
}

#Preview {
    LiveKeyScanView { _ in }
}

#Preview("Hebrew (RTL)") {
    LiveKeyScanView { _ in }
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    LiveKeyScanView { _ in }
        .preferredColorScheme(.dark)
}
