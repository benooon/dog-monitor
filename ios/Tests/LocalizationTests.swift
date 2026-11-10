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

    func testHebrewIsRightToLeft() {
        XCTAssertEqual(Locale.Language(identifier: "he").characterDirection, .rightToLeft)
    }

    func testAppDeclaresHebrew() {
        let localizations = Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]
        XCTAssertEqual(Set(localizations ?? []), ["en", "he"])
    }
}
