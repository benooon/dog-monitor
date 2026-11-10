import DogMonitorCore
import PhotosUI
import SwiftUI

/// "Rex's profile": the owner edits what "Meet your dog" asked. Saving a new age, habits or
/// alert style re-applies the dog's alert plan to the owner's notifications, after asking.
struct DogProfileEditor: View {
    @State private var model: DogOnboardingModel
    /// The stored photo, shown until the owner picks a new one or removes it.
    let storedPhoto: UIImage?
    /// Called after a successful save with the saved dog and the photo the phone now has for it.
    let onSaved: (DogDTO, UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var item: PhotosPickerItem?
    @State private var takesPhoto = false
    @State private var confirmsAlerts = false
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize = DogProfileEditor.avatarBaseSize

    private static let avatarBaseSize: CGFloat = 112

    init(dog: DogDTO, api: DogMonitorAPI, storedPhoto: UIImage?, onSaved: @escaping (DogDTO, UIImage?) -> Void) {
        _model = State(initialValue: DogOnboardingModel(api: api, dog: dog))
        self.storedPhoto = storedPhoto
        self.onSaved = onSaved
    }

    /// What the avatar shows right now.
    private var shownPhoto: UIImage? {
        model.photo ?? (model.removesPhoto ? nil : storedPhoto)
    }

    var body: some View {
        Form {
            photoSection
            Section("Name") {
                TextField("Your dog's name", text: $model.name)
                    .textContentType(.name)
                    .submitLabel(.done)
            }
            Section("Age") {
                Picker("Age", selection: $model.lifeStage) {
                    ForEach(DogLifeStage.allCases, id: \.self) { stage in
                        Label {
                            Text(stage.title)
                            Text(stage.subtitle)
                        } icon: {
                            Image(systemName: stage.systemImage)
                        }
                        .tag(Optional(stage))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                ForEach(DogTrait.allCases, id: \.self) { trait in
                    Toggle(isOn: Binding(
                        get: { model.traits.contains(trait) },
                        set: { _ in model.toggle(trait) }
                    )) {
                        Label(trait.title, systemImage: trait.systemImage)
                    }
                }
            } header: {
                Text("When \(model.displayName) is alone")
            }
            Section {
                Picker("Alerts", selection: $model.alertStyle) {
                    ForEach(DogAlertStyle.allCases, id: \.self) { style in
                        Label {
                            Text(style.title)
                            style.subtitle(dogName: model.displayName)
                        } icon: {
                            Image(systemName: style.systemImage)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Alerts")
            } footer: {
                Text("Changing these updates your notification settings.")
            }
            if model.saveFailed {
                Section {
                    Label {
                        Text("Couldn't save \(model.displayName)'s profile. Check your connection and try again.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(Text("\(model.displayName)'s profile"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button("Save") {
                        if model.changesAlerts {
                            confirmsAlerts = true
                        } else {
                            save(appliesAlerts: false)
                        }
                    }
                    .disabled(model.validName == nil)
                }
            }
        }
        .confirmationDialog(
            Text("Update your alerts for \(model.displayName)?"),
            isPresented: $confirmsAlerts,
            titleVisibility: .visible
        ) {
            Button("Save and update alerts") { save(appliesAlerts: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your notification settings will follow the new profile. You can still change them in Notifications.")
        }
        .sensoryFeedback(.error, trigger: model.saveFailed) { _, failed in failed }
        .dogPhotoPicking(item: $item, takesPhoto: $takesPhoto) { model.setPhoto($0) }
    }

    private var photoSection: some View {
        Section {
            VStack(spacing: DS.Spacing.m) {
                DogAvatar(name: model.displayName, image: shownPhoto, size: min(avatarSize, Self.avatarBaseSize * 2))
                PhotosPicker(selection: $item, matching: .images) {
                    Text(shownPhoto == nil ? "Choose a photo" : "Change photo")
                }
                .buttonStyle(.borderless)
                if CameraPicker.isAvailable {
                    Button("Take a photo") { takesPhoto = true }
                        .buttonStyle(.borderless)
                }
                if shownPhoto != nil {
                    Button("Remove photo", role: .destructive) {
                        model.removePhoto()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.s)
        }
        .listRowBackground(Color.clear)
    }

    private func save(appliesAlerts: Bool) {
        Task {
            guard await model.save(appliesAlerts: appliesAlerts), let dog = model.savedDog else { return }
            let photo: UIImage? = if model.photoUploaded { model.photo } else if dog.hasPhoto { storedPhoto } else { nil }
            onSaved(dog, photo)
            dismiss()
        }
    }
}

#Preview {
    NavigationStack {
        DogProfileEditor(
            dog: HouseholdDTO.demo.dogs[0],
            api: DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!),
            storedPhoto: DogPhotoStore.samplePortrait()
        ) { _, _ in }
    }
}

#Preview("Hebrew (RTL)") {
    NavigationStack {
        DogProfileEditor(
            dog: HouseholdDTO.demo.dogs[0],
            api: DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!),
            storedPhoto: nil
        ) { _, _ in }
    }
    .environment(\.locale, Locale(identifier: "he"))
    .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    NavigationStack {
        DogProfileEditor(
            dog: HouseholdDTO.demo.dogs[0],
            api: DogMonitorAPI(baseURL: URL(string: "https://example.invalid")!),
            storedPhoto: DogPhotoStore.samplePortrait()
        ) { _, _ in }
    }
    .preferredColorScheme(.dark)
}
