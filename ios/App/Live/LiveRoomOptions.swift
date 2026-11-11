import DogMonitorCore
@preconcurrency import LiveKit

/// Room options shared by the camera and viewers, so both sides encrypt the same way.
enum LiveRoomOptions {
    /// End-to-end encryption with the household's shared key, or plain options without one.
    static func make(key: LiveKey?) -> RoomOptions {
        guard let key else { return RoomOptions() }
        let provider = BaseKeyProvider(isSharedKey: true, sharedKey: key.passphrase)
        return RoomOptions(encryptionOptions: EncryptionOptions(keyProvider: provider))
    }
}
