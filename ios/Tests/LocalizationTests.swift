import XCTest

/// Checks the compiled String Catalog: every UI key used so far has a Hebrew translation.
final class LocalizationTests: XCTestCase {
    private static let uiKeys = [
        "Camera",
        "Viewer",
        "Leave this phone at home to watch your dog.",
        "Watch live and get alerts on your own phone.",
        "How will this device be used?",
        "Change role",
        "Sign in to watch your dog from anywhere.",
        "Sign in failed. Please try again.",
        "Something went wrong. Please try again.",
        "Household name",
        "Dog's name (optional)",
        "Family members and cameras join your household later with an invite.",
        "Create",
        "Create your household",
        "Sign out",
        "Cameras",
        "Dogs",
        "Online",
        "Offline",
        "No cameras yet. Pair a spare iPhone as a camera.",
        "Starting camera…",
        "Camera access is off. Allow it in Settings to use this phone as a camera.",
        "Open Settings",
        "Couldn't start the camera.",
        "Try again",
        "Keep this phone plugged in and the app open.",
        "Start camera",
        "Stop camera",
        "Tap the screen to show the preview.",
        "Camera on",
        "Microphone off — barking can't be detected.",
        "Barks in the last minute: %lld",
        "%lld watching",
        "Watch live",
        "Mute 1h",
        "Live",
        "Connecting…",
        "Waiting for the camera…",
        "Connection lost. Reconnecting…",
        "This camera already has 5 viewers.",
        "Live view isn't set up on the server yet.",
        "Couldn't open live view.",
        "Pair this camera",
        "Scan the invite QR code from the owner's phone.",
        "Allow camera access to scan, or type the code.",
        "Or type the 6-digit code",
        "Pair",
        "Cancel",
        "This code is invalid or has expired.",
        "Too many attempts. Wait a minute and try again.",
        "Invite",
        "Expires in %@",
        "This invite has expired.",
        "New invite",
        "On the new phone, choose Camera and scan this code, or type the 6 digits. Family members can join with the same code.",
        "Join a household",
        "Invite code",
        "Join",
        "Done",
        "This phone isn't paired yet, so live view is off. Barking is still detected here.",
    ]

    private func bundle(for language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: language, ofType: "lproj"),
            "No \(language).lproj in the app bundle"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    func testHebrewTranslationsExist() throws {
        let hebrew = try bundle(for: "he")
        for key in Self.uiKeys {
            let value = hebrew.localizedString(forKey: key, value: "<missing>", table: nil)
            XCTAssertNotEqual(value, "<missing>", "Missing Hebrew for \"\(key)\"")
            XCTAssertTrue(value.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) },
                          "Hebrew value for \"\(key)\" contains no Hebrew letters: \(value)")
        }
    }

    /// The backend sends these as `loc-key`s (backend/src/notifications/payload.ts); keep the lists in sync.
    private static let pushKeys = [
        "%@ has been barking",
        "Your dog has been barking",
        "%@ is whining or howling",
        "Your dog is whining or howling",
        "%@ is in a forbidden zone",
        "Your dog is in a forbidden zone",
        "%@ is waiting at the door",
        "Your dog is waiting at the door",
        "%@ hasn't been seen for a while",
        "Your dog hasn't been seen for a while",
        "%@ has calmed down",
        "Your dog has calmed down",
        "The camera is offline",
        "The camera's battery is low",
        "The camera is overheating",
        "%@'s daily summary is ready",
        "Your dog's daily summary is ready",
        "%1$@ has been barking for %2$@ min",
        "Your dog has been barking for %@ min",
        "%1$@ has been whining for %2$@ min",
        "Your dog has been whining for %@ min",
        "%1$@ has been at the door for %2$@ min",
        "Your dog has been at the door for %@ min",
    ]

    func testPushCopyIsLocalized() throws {
        let hebrew = try bundle(for: "he")
        for key in Self.pushKeys {
            let value = hebrew.localizedString(forKey: key, value: "<missing>", table: nil)
            XCTAssertNotEqual(value, "<missing>", "Missing Hebrew push copy for \"\(key)\"")
            XCTAssertEqual(value.components(separatedBy: "%").count, key.components(separatedBy: "%").count,
                           "Placeholder count differs for \"\(key)\"")
        }
    }

    func testHebrewIsRightToLeft() {
        XCTAssertEqual(Locale.Language(identifier: "he").characterDirection, .rightToLeft)
    }

    func testAppDeclaresHebrew() {
        let localizations = Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]
        XCTAssertEqual(Set(localizations ?? []), ["en", "he"])
    }
}
