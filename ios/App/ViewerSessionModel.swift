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
    /// The dogs' photos, shared by every screen that shows a dog.
    private(set) var dogPhotos: DogPhotoStore
    /// The dog whose alert style was just applied to this family member's notifications, for a
    /// one-line note on the home screen (nil once dismissed).
    private(set) var dogAlertsAppliedFor: String?
    /// Realtime presence + watch signals, while the viewer home is shown.
    private(set) var realtime: ViewerRealtime?
    /// Premium purchases and plan, for the household owner only.
    private(set) var subscription: SubscriptionModel?

    /// Sample data for previews and CI screenshots: never touches the network or the keychain.
    private(set) var isDemo = false

    /// This phone's copy of the household's live video key: made here on the owner's phone,
    /// scanned or opened from an invite on every other phone (nil until then).
    private(set) var liveKey: LiveKey?

    private var api: DogMonitorAPI
    private let credentials: CredentialStore
    private let liveKeys: LiveKeyStore

    init(baseURL: URL = AppConfig.apiBaseURL, store: any SecureStore = KeychainStore()) {
        let credentials = CredentialStore(store: store)
        self.credentials = credentials
        liveKeys = LiveKeyStore(store: store)
        dogPhotos = DogPhotoStore()
        api = DogMonitorAPI(baseURL: baseURL, credential: credentials.load())
        liveKey = liveKeys.load()
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
        guard !isDemo else { return }
        await perform {
            household = try await api.household()
        }
        updateSubscription()
        if let household, household.role == .owner {
            await ensureLiveKey(for: household)
        }
        await loadSnapshots()
        if let dogs = household?.dogs {
            await dogPhotos.load(dogs, api: api)
        }
        if let household, let dog = await MemberDogAlerts.applyIfNeeded(household: household, api: api) {
            dogAlertsAppliedFor = dog.name
        }
    }

    func dismissDogAlertsNote() {
        dogAlertsAppliedFor = nil
    }

    /// Only the owner buys Premium, so only the owner's phone reports App Store transactions.
    private func updateSubscription() {
        guard let household, household.role == .owner else {
            subscription?.stop()
            subscription = nil
            return
        }
        guard subscription?.householdId != household.id else { return }
        subscription?.stop()
        let premium = SubscriptionModel(api: api, householdId: household.id)
        subscription = premium
        premium.start()
    }

    /// Owner only: makes the household's live key the first time, and a new one when someone
    /// who held it left (the server asks), then tells the server that live video is encrypted
    /// and the key's id. The key is saved before the server hears anything, and only the flag
    /// and the id are sent. Best effort: retried on the next load.
    private func ensureLiveKey(for household: HouseholdDTO) async {
        let action = LiveEncryption.ownerAction(
            key: liveKey,
            householdEncrypted: household.liveEncrypted ?? false,
            householdKeyId: household.liveKeyId,
            rotationNeeded: household.liveKeyRotationNeeded ?? false
        )
        switch action {
        case .none:
            return
        case .createKey, .replaceLostKey, .rotateKey:
            let key = LiveKey.generate()
            do {
                try liveKeys.save(key)
            } catch {
                return
            }
            liveKey = key
        case .markEncrypted:
            break
        }
        try? await api.markLiveEncrypted(keyId: liveKey?.id)
    }

    /// A key scanned from the owner's invite QR code by a phone already in the household.
    func saveLiveKey(_ key: LiveKey) {
        do {
            try liveKeys.save(key)
            liveKey = key
        } catch {
            errorMessage = String(localized: "Couldn't save the code. Try again.")
        }
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

    /// Looks up who an invite comes from, so the person can confirm before joining
    /// (nil on failure; see `errorMessage`).
    func previewInvite(code: String) async -> InvitePreviewDTO? {
        guard let tokenOrCode = PairingCode.parse(code) else { return nil }
        var preview: InvitePreviewDTO?
        await perform {
            do {
                preview = try await api.invitePreview(tokenOrCode)
            } catch let error as APIError where error.code == "invalid_or_expired_invite" {
                errorMessage = String(localized: "This invite has expired or was already used. Ask for a new one.")
            } catch let error as APIError where error.code == "too_many_attempts" {
                errorMessage = String(localized: "Too many tries. Wait a few minutes, then try again.")
            }
        }
        return preview
    }

    /// Joins an existing household with an invite code (or scanned token) instead of creating one.
    /// - Parameter liveKey: the household's live key from the invite link, if it carried one.
    func joinHousehold(code: String, liveKey: LiveKey? = nil) async {
        guard let tokenOrCode = PairingCode.parse(code) else { return }
        await perform {
            _ = try await api.acceptInviteAsMember(tokenOrCode)
            if let key = liveKey ?? PairingCode.liveKey(in: code) {
                try? liveKeys.save(key)
                self.liveKey = key
            }
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

    /// Owner only: a one-hour key for the training export script (nil on failure).
    func trainingExportToken() async -> String? {
        var token: String?
        await perform {
            token = try await api.trainingExportToken()
        }
        return token
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
        return PairingCode.inviteLink(token: invite.token, baseURL: api.baseURL, liveKey: liveKey)
    }

    /// The signed-in API client, for screens that call it directly (live view).
    var authorizedAPI: DogMonitorAPI { api }

    func startRealtime() {
        guard realtime == nil, case .user = api.credential else { return }
        let realtime = ViewerRealtime(api: api)
        self.realtime = realtime
        realtime.start()
    }

    /// Writes the user's data export to a temporary JSON file for the share sheet (nil on failure).
    func exportMyData() async -> URL? {
        var file: URL?
        await perform {
            let data = try await api.exportMyData()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dog-monitor-my-data.json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            file = url
        }
        return file
    }

    /// Permanently deletes the account on the server, then signs out. An owner who still has other
    /// members is asked to remove them first.
    func deleteAccount() async {
        await perform {
            do {
                try await api.deleteAccount()
            } catch let error as APIError where error.isHouseholdHasMembers {
                errorMessage = String(localized: "Others are still in your household. Remove them first, then delete your account.")
                return
            }
            try? liveKeys.clear()
            liveKey = nil
            signOut()
        }
    }

    func signOut() {
        PushRegistry.shared.deactivate()
        realtime?.stop()
        realtime = nil
        subscription?.stop()
        subscription = nil
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

extension ViewerSessionModel {
    /// A signed-in owner with two cameras and a dog, for previews and CI screenshots.
    static var demo: ViewerSessionModel {
        let model = ViewerSessionModel(baseURL: URL(string: "https://example.invalid")!, store: InMemorySecureStore())
        model.isDemo = true
        model.household = .demo
        model.dogPhotos = DogPhotoStore(directory: nil)
        if let rex = model.household?.dogs.first {
            model.dogPhotos.store(DogPhotoStore.samplePortrait(), for: rex)
        }
        return model
    }
}

extension HouseholdDTO {
    /// Two cameras (one resting dog, one offline), two phones and a dog.
    static var demo: HouseholdDTO {
        let id = UUID()
        let owner = UUID()
        let now = Date.now
        return HouseholdDTO(
            id: id,
            name: "Home",
            ownerId: owner,
            role: .owner,
            members: [
                MemberDTO(userId: owner, name: "Ben", role: .owner),
                MemberDTO(userId: UUID(), name: "Noa", role: .member),
            ],
            dogs: [
                DogDTO(
                    id: UUID(), householdId: id, name: "Rex",
                    lifeStage: .adult, traits: [.barksAtNoises, .waitsAtDoor], alertStyle: .balanced,
                    photoUpdatedAt: now, createdAt: now
                ),
            ],
            devices: [
                DeviceDTO(
                    id: UUID(), householdId: id, name: "Living room", role: .camera,
                    lastHeartbeatAt: now, battery: 0.8, charging: true,
                    dogState: DogState.resting.rawValue, createdAt: now
                ),
                DeviceDTO(
                    id: UUID(), householdId: id, name: "Kitchen", role: .camera,
                    lastHeartbeatAt: now.addingTimeInterval(-3600), createdAt: now
                ),
                DeviceDTO(id: UUID(), householdId: id, userId: owner, name: "Ben's iPhone", role: .viewer, createdAt: now),
            ]
        )
    }
}
