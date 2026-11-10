import DogMonitorCore
import SwiftUI

/// Shows "Meet your dog" to the household owner once: right after creating the household, or
/// on the next launch for a household whose dog has no profile yet. Skipping also counts.
private struct DogOnboardingPresenter: ViewModifier {
    let session: ViewerSessionModel
    let isOwner: Bool

    @State private var onboarding: DogOnboardingModel?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $onboarding) { model in
                DogOnboardingView(model: model) {
                    finish()
                } onFinish: {
                    // Show the photo just picked right away instead of downloading it again.
                    if model.photoUploaded, let photo = model.photo, let dog = model.savedDog {
                        session.dogPhotos.store(photo, for: dog)
                    }
                    finish()
                    Task { await session.loadHousehold() }
                }
                .interactiveDismissDisabled()
            }
            .onChange(of: session.household?.id, initial: true) {
                offerIfNeeded()
            }
    }

    private func offerIfNeeded() {
        guard onboarding == nil, isOwner, !session.isDemo, let household = session.household else { return }
        let dog = household.dogs.first
        guard dog?.alertStyle == nil, !DogOnboardingRecord.isDone(householdId: household.id) else { return }
        onboarding = DogOnboardingModel(api: session.authorizedAPI, dog: dog, hasZones: household.hasForbiddenZone)
    }

    private func finish() {
        if let id = session.household?.id {
            DogOnboardingRecord.markDone(householdId: id)
        }
        onboarding = nil
    }
}

/// Remembers per household that "Meet your dog" was shown, so it never nags.
enum DogOnboardingRecord {
    private static func key(_ householdId: UUID) -> String {
        "dogOnboardingDone.\(householdId.uuidString.lowercased())"
    }

    static func isDone(householdId: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(householdId))
    }

    static func markDone(householdId: UUID, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(householdId))
    }
}

extension View {
    /// Presents "Meet your dog" over this view when the owner's household needs it.
    func dogOnboarding(session: ViewerSessionModel, isOwner: Bool) -> some View {
        modifier(DogOnboardingPresenter(session: session, isOwner: isOwner))
    }
}
