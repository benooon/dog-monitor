import AuthenticationServices
import SwiftUI

struct SignInView: View {
    let model: ViewerSessionModel
    @State private var nonce: AppleNonce?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "pawprint.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Dog Monitor")
                .font(.largeTitle.bold())
            Text("Sign in to watch your dog from anywhere.")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            if let message = model.errorMessage {
                Text(message)
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
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .disabled(model.isWorking)
            .accessibilityIdentifier("sign-in-with-apple")
        }
        .padding()
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
