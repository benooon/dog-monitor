import DogMonitorCore
import Foundation
import Observation

/// Drives viewer onboarding: Sign in with Apple → create household → ready.
@MainActor
@Observable
final class ViewerSessionModel {
    private(set) var state: OnboardingState = .loading
    private(set) var isWorking = false
    var errorMessage: String?

    private var api: DogMonitorAPI
    private let credentials: CredentialStore

    init(baseURL: URL = AppConfig.apiBaseURL, store: any SecureStore = KeychainStore()) {
        let credentials = CredentialStore(store: store)
        self.credentials = credentials
        api = DogMonitorAPI(baseURL: baseURL, credential: credentials.load())
    }

    /// Validates the stored token on launch.
    func restore() async {
        guard case .user = api.credential else {
            state = .signedOut
            return
        }
        await refresh()
    }

    func signIn(identityToken: String, name: String?) async {
        await perform {
            let auth = try await api.signInWithApple(identityToken: identityToken, name: name)
            let credential = APICredential.user(token: auth.token)
            try credentials.save(credential)
            api = api.with(credential: credential)
            state = OnboardingState.from(try await api.me())
        }
    }

    func createHousehold(name: String, dogName: String?) async {
        guard let name = HouseholdNameRules.validated(name) else { return }
        await perform {
            _ = try await api.createHousehold(name: name)
            if let dogName = dogName.flatMap(HouseholdNameRules.validated) {
                _ = try await api.createDog(name: dogName)
            }
            state = OnboardingState.from(try await api.me())
        }
    }

    func signOut() {
        try? credentials.clear()
        api = api.with(credential: .none)
        state = .signedOut
    }

    func reportSignInFailure() {
        errorMessage = String(localized: "Sign in failed. Please try again.")
    }

    private func refresh() async {
        await perform {
            state = OnboardingState.from(try await api.me())
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch let error as APIError where error.isUnauthorized {
            signOut()
        } catch {
            errorMessage = String(localized: "Something went wrong. Please try again.")
            if state == .loading { state = .signedOut }
        }
    }
}
