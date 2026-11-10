import DogMonitorCore
import Foundation
import Observation

/// Drives viewer onboarding: Sign in with Apple → create household → ready.
@MainActor
@Observable
final class ViewerSessionModel {
    private(set) var state: OnboardingState = .loading
    private(set) var isWorking = false
    /// Full household (cameras, dogs) for the viewer home, loaded once ready.
    private(set) var household: HouseholdDTO?
    var errorMessage: String?
    /// Latest snapshot URL per camera (empty until the backend has storage).
    private(set) var snapshots: [UUID: URL] = [:]
    /// Realtime presence + watch signals, while the viewer home is shown.
    private(set) var realtime: ViewerRealtime?

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

    func signIn(identityToken: String, nonce: String, name: String?) async {
        await perform {
            let auth = try await api.signInWithApple(identityToken: identityToken, nonce: nonce, name: name)
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

    func loadHousehold() async {
        await perform {
            household = try await api.household()
        }
        await loadSnapshots()
    }

    /// Best effort: storage may not be configured yet, which is fine for the home screen.
    private func loadSnapshots() async {
        guard let list = try? await api.cameraSnapshots() else { return }
        snapshots = Dictionary(list.map { ($0.cameraId, $0.url) }, uniquingKeysWith: { _, new in new })
    }

    /// Owner only: a one-time invite for a camera or family member (nil on failure; see `errorMessage`).
    func createInvite() async -> InviteDTO? {
        var invite: InviteDTO?
        await perform {
            invite = try await api.createInvite()
        }
        return invite
    }

    /// Joins an existing household with an invite code (or scanned token) instead of creating one.
    func joinHousehold(code: String) async {
        guard let tokenOrCode = PairingCode.parse(code) else { return }
        await perform {
            _ = try await api.acceptInviteAsMember(tokenOrCode)
            state = OnboardingState.from(try await api.me())
        }
    }

    /// Owner only: removes a family member and signs their phones out. Returns whether it worked.
    func removeMember(_ member: MemberDTO) async -> Bool {
        var removed = false
        await perform {
            try await api.removeMember(userId: member.userId)
            removed = true
        }
        if removed { await loadHousehold() }
        return removed
    }

    /// Owner only: the training-data opt-in.
    func setShareTrainingData(_ enabled: Bool) async {
        await perform {
            try await api.setShareTrainingData(enabled)
        }
        await loadHousehold()
    }

    /// Owner only: revokes a camera or phone (a camera must be paired again).
    func revokeDevice(_ device: DeviceDTO) async -> Bool {
        var revoked = false
        await perform {
            _ = try await api.revokeDevice(id: device.id)
            revoked = true
        }
        if revoked { await loadHousehold() }
        return revoked
    }

    /// A shareable link for `invite`, or nil when the server address can't make one.
    func inviteLink(for invite: InviteDTO) -> URL? {
        guard api.baseURL.scheme == "https" else { return nil }
        return PairingCode.inviteLink(token: invite.token, baseURL: api.baseURL)
    }

    /// The signed-in API client, for screens that call it directly (live view).
    var authorizedAPI: DogMonitorAPI { api }

    func startRealtime() {
        guard realtime == nil, case .user = api.credential else { return }
        let realtime = ViewerRealtime(api: api)
        self.realtime = realtime
        realtime.start()
    }

    func signOut() {
        PushRegistry.shared.deactivate()
        realtime?.stop()
        realtime = nil
        household = nil
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
