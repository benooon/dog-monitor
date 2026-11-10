import DogMonitorCore
import Foundation
import Observation
import UIKit

/// "Meet your dog": the owner's answers, step by step, then one save that creates (or updates)
/// the dog, stores the photo and turns the answers into the owner's alert settings.
@MainActor
@Observable
final class DogOnboardingModel: Identifiable {
    enum Step: Hashable, CaseIterable {
        case name, photo, age, alone, alerts, summary
    }

    let id = UUID()
    var name: String
    var photo: UIImage?
    var lifeStage: DogLifeStage?
    var traits: Set<DogTrait>
    var alertStyle: DogAlertStyle
    /// The owner asked to remove the stored photo (profile editor).
    private(set) var removesPhoto = false
    private(set) var isSaving = false
    private(set) var saveFailed = false
    /// Whether a camera already has a no-go zone, so the summary can say if one is still needed.
    let hasZones: Bool
    /// Another dog in a household that already has one: no alerts question (it shares the
    /// household's alert style) and its habits only add alerts.
    let isAnotherDog: Bool

    private let api: DogMonitorAPI
    /// The dog being described: one created by an earlier attempt, or one the household already had.
    private var dog: DogDTO?
    /// The dog as it was when the screen opened, to tell what the owner changed.
    private let original: DogDTO?

    init(api: DogMonitorAPI, dog: DogDTO? = nil, hasZones: Bool = false) {
        self.api = api
        self.dog = dog
        original = dog
        self.hasZones = hasZones
        isAnotherDog = false
        name = dog?.name ?? ""
        lifeStage = dog?.lifeStage
        traits = Set(dog?.traits ?? [])
        alertStyle = dog?.alertStyle ?? .balanced
    }

    /// A new dog for a household that already has `firstDog`.
    init(api: DogMonitorAPI, anotherDogAfter firstDog: DogDTO, hasZones: Bool = false) {
        self.api = api
        dog = nil
        original = nil
        self.hasZones = hasZones
        isAnotherDog = true
        name = ""
        lifeStage = nil
        traits = []
        alertStyle = firstDog.alertStyle ?? .balanced
    }

    /// The questions in order.
    var steps: [Step] {
        isAnotherDog ? Step.allCases.filter { $0 != .alerts } : Step.allCases
    }

    /// The dog as last saved, with its photo version once the photo is stored.
    var savedDog: DogDTO? { dog }
    /// Whether `photo` is the dog's stored photo (its upload worked).
    private(set) var photoUploaded = false

    /// The name as it will be saved, or nil while it is empty.
    var validName: String? {
        HouseholdNameRules.validated(name)
    }

    /// The name for titles; a gentle fallback keeps copy readable before one is typed.
    var displayName: String {
        validName ?? String(localized: "your dog")
    }

    var personalization: DogPersonalization {
        DogPersonalization(lifeStage: lifeStage, traits: traits, alertStyle: alertStyle)
    }

    var promises: [DogPersonalization.Promise] {
        personalization.promises(hasZones: hasZones)
    }

    /// Whether saving would change the alerts: the dog had no profile yet, or its age, habits
    /// or alert style changed. Name and photo alone leave notification settings alone.
    var changesAlerts: Bool {
        guard let original, let originalStyle = original.alertStyle else { return true }
        return lifeStage != original.lifeStage
            || traits != Set(original.traits)
            || alertStyle != originalStyle
    }

    func toggle(_ trait: DogTrait) {
        if traits.contains(trait) {
            traits.remove(trait)
        } else {
            traits.insert(trait)
        }
    }

    /// Keeps a square, phone-sized copy of the picked image.
    func setPhoto(data: Data) {
        guard let image = UIImage(data: data) else { return }
        photo = DogPhoto.square(image, side: DogPhoto.uploadSide)
        removesPhoto = false
    }

    /// Keeps a photo the owner already cropped (square, upload-sized).
    func setPhoto(_ image: UIImage) {
        photo = image
        removesPhoto = false
    }

    /// Drops the picked photo and, on save, the stored one.
    func removePhoto() {
        photo = nil
        removesPhoto = true
    }

    /// Saves everything. Returns true when the dog and the alert settings are stored; a photo
    /// that fails to upload does not block the rest (it can be added again from the household).
    /// - Parameter appliesAlerts: false keeps the owner's notification settings as they are.
    func save(appliesAlerts: Bool = true) async -> Bool {
        guard let name = validName, !isSaving else { return false }
        isSaving = true
        saveFailed = false
        defer { isSaving = false }
        do {
            let input = personalization.dogInput(name: name)
            var saved: DogDTO
            if let dog {
                saved = try await api.updateDog(id: dog.id, input)
            } else {
                saved = try await api.createDog(input)
            }
            dog = saved
            if let photo, let jpeg = DogPhoto.jpeg(photo) {
                if let withPhoto = try? await api.uploadDogPhoto(id: saved.id, jpeg: jpeg) {
                    saved = withPhoto
                    dog = saved
                    photoUploaded = true
                }
            } else if removesPhoto, saved.hasPhoto {
                saved = try await api.deleteDogPhoto(id: saved.id)
                dog = saved
            }
            guard appliesAlerts else { return true }
            var settings = NotificationSettings(try await api.notificationPrefs())
            if isAnotherDog {
                personalization.add(to: &settings)
            } else {
                personalization.apply(to: &settings)
            }
            _ = try await api.replaceNotificationPrefs(settings.requestPrefs())
            return true
        } catch {
            saveFailed = true
            return false
        }
    }
}

extension DogOnboardingModel {
    /// Sample answers for previews and CI screenshots: never saves.
    static func preview(
        name: String = "Rex",
        traits: Set<DogTrait> = [.barksAtNoises, .waitsAtDoor],
        lifeStage: DogLifeStage? = .adult
    ) -> DogOnboardingModel {
        let model = DogOnboardingModel(api: DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!))
        model.name = name
        model.traits = traits
        model.lifeStage = lifeStage
        return model
    }
}
