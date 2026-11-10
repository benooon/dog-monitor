import DogMonitorCore
import PhotosUI
import SwiftUI

/// "Meet your dog": one question per screen, the dog's name in every title, and a summary of
/// what the answers turn on. Shown once to the owner after creating a household.
struct DogOnboardingView: View {
    @Bindable var model: DogOnboardingModel
    var autofocus = true
    let onSkip: () -> Void
    let onFinish: () -> Void

    @State private var path: [DogOnboardingModel.Step]

    /// - Parameter initialPath: Steps already pushed on top of the name step (previews, screenshots).
    init(
        model: DogOnboardingModel,
        initialPath: [DogOnboardingModel.Step] = [],
        autofocus: Bool = true,
        onSkip: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        _model = Bindable(model)
        self.autofocus = autofocus
        self.onSkip = onSkip
        self.onFinish = onFinish
        _path = State(initialValue: initialPath)
    }

    var body: some View {
        NavigationStack(path: $path) {
            screen(.name)
                .navigationDestination(for: DogOnboardingModel.Step.self) { step in
                    screen(step)
                }
        }
    }

    @ViewBuilder
    private func screen(_ step: DogOnboardingModel.Step) -> some View {
        Group {
            switch step {
            case .name:
                NameStep(model: model, autofocus: autofocus, onSkip: onSkip) { advance(from: .name) }
            case .photo:
                PhotoStep(model: model) { advance(from: .photo) }
            case .age:
                AgeStep(model: model) { advance(from: .age) }
            case .alone:
                AloneStep(model: model) { advance(from: .alone) }
            case .alerts:
                AlertsStep(model: model) { advance(from: .alerts) }
            case .summary:
                SummaryStep(model: model, onFinish: onFinish)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                StepProgress(step: step)
            }
        }
    }

    private func advance(from step: DogOnboardingModel.Step) {
        let steps = DogOnboardingModel.Step.allCases
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        path.append(steps[index + 1])
    }
}

/// A thin bar in the navigation bar: how far along the questions are.
private struct StepProgress: View {
    let step: DogOnboardingModel.Step

    @ScaledMetric private var width: CGFloat = 120

    var body: some View {
        let steps = DogOnboardingModel.Step.allCases
        let position = (steps.firstIndex(of: step) ?? 0) + 1
        ProgressView(value: Double(position), total: Double(steps.count))
            .progressViewStyle(.linear)
            .frame(width: width)
            .accessibilityElement()
            .accessibilityLabel(Text("Step \(position) of \(steps.count)"))
    }
}

// MARK: - Steps

private struct NameStep: View {
    @Bindable var model: DogOnboardingModel
    let autofocus: Bool
    let onSkip: () -> Void
    let next: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        QuestionScreen(
            title: Text("Who are we watching?"),
            message: Text("Let's start with your dog's name.")
        ) {
            TextField(text: $model.name) {
                Text("Your dog's name")
            }
            .font(.title2.weight(.semibold))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.continue)
            .focused($isFocused)
            .onSubmit { if model.validName != nil { next() } }
            .padding(DS.Spacing.l)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
            .accessibilityIdentifier("dog-onboarding-name")
        } actions: {
            PrimaryButton(title: "Continue", action: next)
                .disabled(model.validName == nil)
                .accessibilityIdentifier("dog-onboarding-continue")
            SecondaryActionButton(title: "Skip for now", action: onSkip)
        }
        .onAppear { if autofocus { isFocused = true } }
    }
}

private struct PhotoStep: View {
    @Bindable var model: DogOnboardingModel
    let next: () -> Void

    @State private var item: PhotosPickerItem?
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 168
    /// The edit badge on the avatar: at least a 44 pt target.
    @ScaledMetric private var badgeSize: CGFloat = 44

    var body: some View {
        QuestionScreen(
            title: Text("Add a photo of \(model.displayName)"),
            message: Text("It shows up on your home screen and Lock Screen.")
        ) {
            PhotosPicker(selection: $item, matching: .images) {
                DogAvatar(name: model.displayName, image: model.photo, size: min(avatarSize, 240))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: model.photo == nil ? "plus" : "pencil")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: badgeSize, height: badgeSize)
                            .background(.tint, in: Circle())
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: DS.Spacing.xs))
                            .accessibilityHidden(true)
                    }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.l)
            .accessibilityLabel(model.photo == nil ? Text("Choose a photo") : Text("Change photo"))
        } actions: {
            if model.photo == nil {
                PhotosPicker(selection: $item, matching: .images) {
                    Label("Choose a photo", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .primaryButtonStyle()
                SecondaryActionButton(title: "Not now", action: next)
            } else {
                PrimaryButton(title: "Continue", action: next)
                PhotosPicker(selection: $item, matching: .images) {
                    Text("Change photo")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    model.setPhoto(data: data)
                }
            }
        }
    }
}

private struct AgeStep: View {
    @Bindable var model: DogOnboardingModel
    let next: () -> Void

    var body: some View {
        QuestionScreen(title: Text("How old is \(model.displayName)?")) {
            VStack(spacing: DS.Spacing.m) {
                ForEach(DogLifeStage.allCases, id: \.self) { stage in
                    ChoiceCard(
                        title: stage.title,
                        subtitle: Text(stage.subtitle),
                        systemImage: stage.systemImage,
                        isSelected: model.lifeStage == stage
                    ) {
                        model.lifeStage = stage
                    }
                }
            }
        } actions: {
            PrimaryButton(title: "Continue", action: next)
        }
    }
}

private struct AloneStep: View {
    @Bindable var model: DogOnboardingModel
    let next: () -> Void

    var body: some View {
        QuestionScreen(
            title: Text("What does \(model.displayName) do when alone?"),
            message: Text("Choose all that fit. This decides which alerts we send.")
        ) {
            VStack(spacing: DS.Spacing.m) {
                ForEach(DogTrait.allCases, id: \.self) { trait in
                    ChoiceCard(
                        title: trait.title,
                        systemImage: trait.systemImage,
                        isSelected: model.traits.contains(trait)
                    ) {
                        model.toggle(trait)
                    }
                }
            }
        } actions: {
            PrimaryButton(title: "Continue", action: next)
        }
    }
}

private struct AlertsStep: View {
    @Bindable var model: DogOnboardingModel
    let next: () -> Void

    var body: some View {
        QuestionScreen(
            title: Text("How much should we tell you?"),
            message: Text("You can change this anytime in Notifications.")
        ) {
            VStack(spacing: DS.Spacing.m) {
                ForEach(DogAlertStyle.allCases, id: \.self) { style in
                    ChoiceCard(
                        title: style.title,
                        subtitle: style.subtitle(dogName: model.displayName),
                        systemImage: style.systemImage,
                        isSelected: model.alertStyle == style,
                        badge: style == .balanced ? "Recommended" : nil
                    ) {
                        model.alertStyle = style
                    }
                }
            }
        } actions: {
            PrimaryButton(title: "Continue", action: next)
        }
    }
}

private struct SummaryStep: View {
    @Bindable var model: DogOnboardingModel
    let onFinish: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 112
    @ScaledMetric(relativeTo: .body) private var promiseSymbolWidth: CGFloat = 28
    @State private var failures = 0

    var body: some View {
        QuestionScreen(title: Text("Here's how we'll watch \(model.displayName)")) {
            VStack(alignment: .leading, spacing: DS.Spacing.xxl) {
                DogAvatar(name: model.displayName, image: model.photo, size: min(avatarSize, 180))
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    ForEach(model.promises, id: \.self) { promise in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.m) {
                            Image(systemName: promise.systemImage)
                                .foregroundStyle(.tint)
                                // One column for every symbol, so the sentences line up.
                                .frame(width: promiseSymbolWidth)
                                .accessibilityHidden(true)
                            promise.text(dogName: model.displayName)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(DS.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                if model.saveFailed {
                    Label {
                        Text("Couldn't save \(model.displayName)'s profile. Check your connection and try again.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.red)
                }
            }
        } actions: {
            PrimaryButton(title: "Looks good", isLoading: model.isSaving) {
                Task {
                    if await model.save() {
                        onFinish()
                    } else {
                        failures += 1
                    }
                }
            }
            .accessibilityIdentifier("dog-onboarding-done")
        }
        .sensoryFeedback(.error, trigger: failures)
    }
}

#Preview {
    DogOnboardingView(model: .preview(name: ""), autofocus: false, onSkip: {}, onFinish: {})
}

#Preview("Hebrew (RTL)") {
    DogOnboardingView(model: .preview(name: "רקס"), initialPath: [.photo, .age, .alone], autofocus: false, onSkip: {}, onFinish: {})
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    DogOnboardingView(
        model: .preview(),
        initialPath: [.photo, .age, .alone, .alerts, .summary],
        autofocus: false,
        onSkip: {},
        onFinish: {}
    )
    .preferredColorScheme(.dark)
}
