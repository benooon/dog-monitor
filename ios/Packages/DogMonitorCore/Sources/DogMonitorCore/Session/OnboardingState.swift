import Foundation

/// Where a viewer device is in onboarding. Pure so it can be unit-tested; the app's model drives it.
public enum OnboardingState: Equatable, Sendable {
    /// Checking a stored credential with the backend.
    case loading
    case signedOut
    /// Signed in but not yet in a household.
    case needsHousehold(user: UserDTO)
    case ready(user: UserDTO, household: HouseholdMembershipDTO)

    /// Derives the state from `GET /me`.
    public static func from(_ me: MeResponse) -> OnboardingState {
        if let household = me.households.first {
            return .ready(user: me.user, household: household)
        }
        return .needsHousehold(user: me.user)
    }
}

public enum HouseholdNameRules {
    public static let maxLength = 100

    /// Trimmed name, or nil if it is empty or too long for the backend.
    public static func validated(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }
}
