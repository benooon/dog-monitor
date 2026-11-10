import DogMonitorCore
import Foundation

/// Family members get the dog's alert style too: the first time a member's phone loads a
/// household whose dog has a profile, the owner's "Meet your dog" answers become this person's
/// alert settings. Once per household and phone; afterwards they are theirs to change.
@MainActor
enum MemberDogAlerts {
    private static func key(_ householdId: UUID) -> String {
        "memberDogAlertsApplied.\(householdId.uuidString.lowercased())"
    }

    static func isApplied(householdId: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(householdId))
    }

    /// Applies the dog's alert plan when it is due. Returns the dog it was applied for (to say so
    /// on the home screen), or nil when nothing changed. A failure is tried again next time.
    static func applyIfNeeded(
        household: HouseholdDTO,
        api: DogMonitorAPI,
        defaults: UserDefaults = .standard
    ) async -> DogDTO? {
        guard household.role == .member,
              let dog = household.dogs.first, dog.alertStyle != nil,
              !isApplied(householdId: household.id, defaults: defaults)
        else { return nil }
        do {
            var settings = NotificationSettings(try await api.notificationPrefs())
            DogPersonalization(dog).apply(to: &settings)
            _ = try await api.replaceNotificationPrefs(settings.requestPrefs())
        } catch {
            return nil
        }
        defaults.set(true, forKey: key(household.id))
        return dog
    }
}
