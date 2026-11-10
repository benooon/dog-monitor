import DogMonitorCore
import SwiftUI
import UIKit

/// Pairs this phone as a camera: scan the owner's invite QR code or type the 6-digit code.
struct CameraPairingView: View {
    let onPaired: (APICredential) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var cameraAllowed: Bool?
    @State private var isWorking = false
    @State private var errorMessage: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch cameraAllowed {
                    case true?:
                        QRScannerView { scanned in
                            Task { await pair(scanned) }
                        }
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .listRowInsets(EdgeInsets())
                    case false?:
                        Text("Allow camera access to scan, or type the code.")
                            .foregroundStyle(.secondary)
                    case nil:
                        ProgressView()
                    }
                } footer: {
                    Text("Scan the invite QR code from the owner's phone.")
                }

                Section("Or type the 6-digit code") {
                    TextField(text: $code) {
                        Text(verbatim: "123456")
                    }
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .accessibilityIdentifier("pairing-code")
                    Button {
                        Task { await pair(code) }
                    } label: {
                        HStack {
                            Text("Pair")
                            if isWorking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(PairingCode.parse(code) == nil || isWorking)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Pair this camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                cameraAllowed = await CaptureService.requestAccess(for: .video)
            }
        }
    }

    private func pair(_ text: String) async {
        guard !isWorking, let tokenOrCode = PairingCode.parse(text) else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let response = try await DogMonitorAPI(baseURL: AppConfig.apiBaseURL).acceptInviteAsCamera(
                tokenOrCode,
                deviceName: UIDevice.current.name,
                model: UIDevice.current.model,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
            let credential = APICredential.device(id: response.device.id, secret: response.deviceSecret)
            try CredentialStore(store: KeychainStore()).save(credential)
            onPaired(credential)
            dismiss()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    static func message(for error: any Error) -> LocalizedStringKey {
        if let error = error as? APIError, error.isCameraLimitReached {
            return "This household has no room for another camera. The owner can get Premium on the Household screen."
        }
        return switch error as? APIError {
        case .http(status: 404, _)?, .http(status: 410, _)?:
            "This code is invalid or has expired."
        case .http(status: 429, _)?:
            "Too many attempts. Wait a minute and try again."
        default:
            "Something went wrong. Please try again."
        }
    }
}
