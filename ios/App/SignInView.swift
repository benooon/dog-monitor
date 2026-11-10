import AuthenticationServices
import SwiftUI

struct SignInView: View {
    let model: ViewerSessionModel
    @State private var nonce: AppleNonce?
    @Environment(\.colorScheme) private var colorScheme

    /// Apple's button has no intrinsic height; this matches a large control and grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var appleButtonHeight: CGFloat = 50

    var body: some View {
        OnboardingScaffold {
            OnboardingHeader(title: "Dog Monitor", message: "Sign in to watch your dog from anywhere.")
        } actions: {
            if let message = model.errorMessage {
                Label {
                    Text(verbatim: message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            }
            SignInWithAppleButton(.signIn) { request in
                let fresh = AppleNonce.random()
                nonce = fresh
                request.requestedScopes = [.fullName]
                request.nonce = fresh.sha256
            } onCompletion: { result in
                handle(result)
            }
            // HIG: white on dark backgrounds, black on light.
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: appleButtonHeight)
            .clipShape(Capsule())
            .disabled(model.isWorking)
            .opacity(model.isWorking ? 0 : 1)
            .overlay {
                if model.isWorking {
                    ProgressView()
                }
            }
            .accessibilityIdentifier("sign-in-with-apple")
        }
        .sensoryFeedback(.error, trigger: model.errorMessage) { _, new in new != nil }
    }

    private func handle(_ result: Result<ASAuthorization, any Error>) {
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let rawNonce = nonce?.raw
        else {
            if case .failure(let error) = result,
               (error as? ASAuthorizationError)?.code == .canceled {
                return
            }
            model.reportSignInFailure()
            return
        }
        let name = credential.fullName.map {
            PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
        }.flatMap { $0.isEmpty ? nil : $0 }
        self.nonce = nil
        Task { await model.signIn(identityToken: token, nonce: rawNonce, name: name) }
    }
}

#Preview {
    SignInView(model: ViewerSessionModel())
}

#Preview("Hebrew (RTL)") {
    SignInView(model: ViewerSessionModel())
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    SignInView(model: ViewerSessionModel())
        .preferredColorScheme(.dark)
}
