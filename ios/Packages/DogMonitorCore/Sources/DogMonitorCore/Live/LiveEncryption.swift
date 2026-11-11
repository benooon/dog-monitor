import Foundation

/// Decides how a camera publishes and a viewer joins live video, given this phone's key and
/// whether the household is marked end-to-end encrypted (from the live token).
///
/// The rules keep the guarantee simple: a phone with the key always encrypts, and once a
/// household (or a camera) is known to be encrypted, nobody falls back to clear video. The
/// server only learns *that* video is encrypted, never the key; a server that lies about the
/// flag can at worst stop live view, not see it, as long as the phones hold the key.
public enum LiveEncryption {
    public enum Mode: Sendable, Equatable {
        /// Join with LiveKit frame encryption using this key.
        case encrypted(LiveKey)
        /// The household has not turned encryption on yet (older households, until the owner's
        /// phone runs this version), so join without it.
        case clear
        /// The household is encrypted but this phone has no key: don't join, ask to scan the
        /// invite QR code on the owner's phone.
        case needsKey
    }

    public static func mode(key: LiveKey?, householdEncrypted: Bool) -> Mode {
        if let key { return .encrypted(key) }
        return householdEncrypted ? .needsKey : .clear
    }

    /// What a viewer does with the camera's video track once it appears.
    public enum TrackDecision: Sendable, Equatable {
        case show
        /// Encrypted video and no key on this phone.
        case needsKey
        /// Clear video from a camera that should be encrypted: never shown (a downgrade).
        case refuse
    }

    /// - Parameters:
    ///   - trackEncrypted: the publication's encryption type is not `none`.
    ///   - cameraPinned: this phone has seen this camera encrypted before (`EncryptedCameraPins`).
    public static func decision(
        trackEncrypted: Bool,
        hasKey: Bool,
        householdEncrypted: Bool,
        cameraPinned: Bool
    ) -> TrackDecision {
        if trackEncrypted { return hasKey ? .show : .needsKey }
        return householdEncrypted || cameraPinned ? .refuse : .show
    }

    /// What the owner's phone does when the household loads.
    public enum OwnerAction: Sendable, Equatable {
        case none
        /// Make a key, keep it, then mark the household encrypted.
        case createKey
        /// The key exists but the server doesn't know the household is encrypted yet (the
        /// earlier mark failed): mark it again.
        case markEncrypted
        /// The household is encrypted but this phone lost the key (new phone without iCloud
        /// Keychain). A new key is made; cameras and family must scan a new invite.
        case replaceLostKey
    }

    public static func ownerAction(hasKey: Bool, householdEncrypted: Bool) -> OwnerAction {
        switch (hasKey, householdEncrypted) {
        case (true, true): .none
        case (true, false): .markEncrypted
        case (false, false): .createKey
        case (false, true): .replaceLostKey
        }
    }
}

/// Cameras this phone has watched with encrypted video. A pinned camera's clear video is
/// refused even if the server says the household is not encrypted (trust on first use).
public struct EncryptedCameraPins {
    static let defaultsKey = "liveVideo.encryptedCameras"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func isPinned(_ cameraId: UUID) -> Bool {
        ids.contains(cameraId.uuidString)
    }

    public func pin(_ cameraId: UUID) {
        var ids = ids
        guard ids.insert(cameraId.uuidString).inserted else { return }
        defaults.set(ids.sorted(), forKey: Self.defaultsKey)
    }

    private var ids: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }
}
