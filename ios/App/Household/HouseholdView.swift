import DogMonitorCore
import SwiftUI
import UIKit

/// Who and what is in the household: family members, cameras and phones. The owner can invite,
/// remove members and remove devices.
struct HouseholdView: View {
    let model: ViewerSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsInvite = false
    @State private var showsPremium = false
    @State private var memberToRemove: MemberDTO?
    @State private var deviceToRemove: DeviceDTO?
    @State private var sharesTrainingData = false
    @State private var copiedExportKey = false
    /// "Meet your dog" for a new dog, while it is shown.
    @State private var addingDog: DogOnboardingModel?

    private var household: HouseholdDTO? { model.household }
    private var isOwner: Bool { household?.role == .owner }

    var body: some View {
        NavigationStack {
            Group {
                if let household {
                    list(for: household)
                } else if let message = model.errorMessage, !model.isWorking {
                    ContentUnavailableView {
                        Label("Couldn't load your household", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: message)
                    } actions: {
                        Button("Try again") {
                            Task { await model.loadHousehold() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsInvite, onDismiss: { Task { await model.loadHousehold() } }) {
                InviteSheet(model: model)
            }
            .fullScreenCover(item: $addingDog) { onboarding in
                DogOnboardingView(model: onboarding) {
                    addingDog = nil
                } onFinish: {
                    if onboarding.photoUploaded, let photo = onboarding.photo, let dog = onboarding.savedDog {
                        model.dogPhotos.store(photo, for: dog)
                    }
                    addingDog = nil
                    Task { await model.loadHousehold() }
                }
                .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showsPremium) {
                if let subscription = model.subscription {
                    PremiumView(model: subscription)
                }
            }
            .confirmationDialog(
                memberToRemove.map { Text("Remove \(Self.displayName(of: $0))?") } ?? Text(verbatim: ""),
                isPresented: isPresented($memberToRemove),
                titleVisibility: .visible,
                presenting: memberToRemove
            ) { member in
                Button("Remove", role: .destructive) {
                    Task { _ = await model.removeMember(member) }
                }
            } message: { _ in
                Text("Their phones stop getting alerts and can't watch live.")
            }
            .confirmationDialog(
                deviceToRemove.map { Text("Remove \($0.name)?") } ?? Text(verbatim: ""),
                isPresented: isPresented($deviceToRemove),
                titleVisibility: .visible,
                presenting: deviceToRemove
            ) { device in
                Button("Remove", role: .destructive) {
                    Task { _ = await model.revokeDevice(device) }
                }
            } message: { device in
                if device.role == .camera {
                    Text("This camera stops watching until you pair it again.")
                } else {
                    Text("This phone stops getting alerts and can't watch live.")
                }
            }
            .refreshable { await model.loadHousehold() }
            .task { await model.loadHousehold() }
        }
    }

    private func list(for household: HouseholdDTO) -> some View {
        List {
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if !household.dogs.isEmpty || isOwner {
                Section("Dogs") {
                    ForEach(household.dogs) { dog in
                        if isOwner {
                            NavigationLink {
                                DogProfileEditor(
                                    dog: dog,
                                    api: model.authorizedAPI,
                                    storedPhoto: model.dogPhotos.image(for: dog)
                                ) { saved, photo in
                                    if let photo {
                                        model.dogPhotos.store(photo, for: saved)
                                    }
                                    Task { await model.loadHousehold() }
                                }
                            } label: {
                                DogRow(dog: dog, photo: model.dogPhotos.image(for: dog))
                            }
                            .accessibilityHint(Text("Edit \(dog.name)'s profile"))
                            .accessibilityIdentifier("household-dog-\(dog.id.uuidString.lowercased())")
                        } else {
                            DogRow(dog: dog, photo: model.dogPhotos.image(for: dog))
                        }
                    }
                    if isOwner {
                        Button {
                            addingDog = household.dogs.first.map {
                                DogOnboardingModel(api: model.authorizedAPI, anotherDogAfter: $0, hasZones: household.hasForbiddenZone)
                            } ?? DogOnboardingModel(api: model.authorizedAPI, hasZones: household.hasForbiddenZone)
                        } label: {
                            Label(household.dogs.isEmpty ? LocalizedStringKey("Add your dog") : "Add another dog", systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("household-add-dog")
                    }
                }
            }

            Section {
                ForEach(household.members, id: \.userId) { member in
                    MemberRow(member: member)
                        .swipeActions {
                            if isOwner, member.role != .owner {
                                Button("Remove", role: .destructive) { memberToRemove = member }
                            }
                        }
                        .contextMenu {
                            if isOwner, member.role != .owner {
                                Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                                    memberToRemove = member
                                }
                            }
                        }
                }
                if isOwner {
                    Button {
                        showsInvite = true
                    } label: {
                        Label("Invite family or pair a camera", systemImage: "person.badge.plus")
                    }
                    .accessibilityIdentifier("household-invite")
                }
            } header: {
                Text("Members")
            }

            let active = household.devices.filter { $0.status == .active }
            deviceSection(
                title: "Cameras",
                devices: active.filter { $0.role == .camera },
                empty: "No cameras yet. Pair a spare iPhone as a camera."
            )
            deviceSection(title: "Phones", devices: active.filter { $0.role == .viewer }, empty: nil)

            if isOwner, let subscription = model.subscription {
                PlanSection(status: subscription.status) { showsPremium = true }
            }

            if isOwner {
                Section {
                    Toggle(isOn: $sharesTrainingData) {
                        Label("Help improve detection", systemImage: "wand.and.stars")
                    }
                    .onChange(of: sharesTrainingData) { _, enabled in
                        guard enabled != (household.shareTrainingData ?? false) else { return }
                        Task { await model.setShareTrainingData(enabled) }
                    }
                    if household.shareTrainingData == true {
                        Button("Copy export key", systemImage: "key") {
                            Task {
                                guard let token = await model.trainingExportToken() else { return }
                                UIPasteboard.general.string = token
                                copiedExportKey = true
                            }
                        }
                        if copiedExportKey {
                            Text("Export key copied. It works for one hour.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Clips your household marks right or wrong are kept for 90 days to train detection. Other clips are still deleted after a week.")
                }
            }

            Section {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
                .accessibilityIdentifier("sign-out")
            }
        }
        .onChange(of: household.shareTrainingData, initial: true) { _, value in
            sharesTrainingData = value ?? false
        }
    }

    @ViewBuilder
    private func deviceSection(title: LocalizedStringKey, devices: [DeviceDTO], empty: LocalizedStringKey?) -> some View {
        if !devices.isEmpty || empty != nil {
            Section(title) {
                if devices.isEmpty, let empty {
                    Text(empty).foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    DeviceRow(device: device, ownerName: ownerName(of: device))
                        .swipeActions {
                            if isOwner {
                                Button("Remove", role: .destructive) { deviceToRemove = device }
                            }
                        }
                        .contextMenu {
                            if isOwner {
                                Button("Remove", systemImage: "trash", role: .destructive) { deviceToRemove = device }
                            }
                        }
                }
            }
        }
    }

    private func ownerName(of device: DeviceDTO) -> String? {
        guard device.role == .viewer, let userId = device.userId else { return nil }
        return household?.members.first { $0.userId == userId }?.name
    }

    static func displayName(of member: MemberDTO) -> String {
        member.name ?? String(localized: "Family member")
    }

    private func isPresented<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Owner only: the household's plan, opening Premium.
private struct PlanSection: View {
    let status: SubscriptionDTO?
    let showPremium: () -> Void

    var body: some View {
        Section {
            Button(action: showPremium) {
                LabeledContent {
                    if let status {
                        Text(status.isPremium ? LocalizedStringKey("Premium") : LocalizedStringKey("Free"))
                    }
                } label: {
                    Label("Plan", systemImage: "star.circle")
                }
            }
            .tint(.primary)
            .accessibilityIdentifier("household-plan")
        } footer: {
            if let status, !status.isPremium {
                Text("Premium lets your household pair up to \(SubscriptionProducts.premiumCameraLimit) cameras.")
            }
        }
    }
}

private struct MemberRow: View {
    let member: MemberDTO

    var body: some View {
        LabeledContent {
            if member.role == .owner {
                Text("Owner")
            }
        } label: {
            Label {
                Text(verbatim: HouseholdView.displayName(of: member))
            } icon: {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DeviceRow: View {
    let device: DeviceDTO
    let ownerName: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Label {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text(verbatim: device.name)
                    if device.role == .camera {
                        let online = device.isOnline(now: context.date)
                        Label {
                            Text(online ? LocalizedStringKey("Online") : LocalizedStringKey("Offline"))
                        } icon: {
                            Image(systemName: "circle.fill")
                                .imageScale(.small)
                                .foregroundStyle(online ? Color.green : Color.secondary)
                        }
                        .labelStyle(StatusDotLabelStyle())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else if let ownerName {
                        Text("\(ownerName)'s phone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: device.role == .camera ? "video" : "iphone")
            }
            .accessibilityElement(children: .combine)
        }
    }

}

/// A small colored dot before a short status, kept tight to the text.
private struct StatusDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            configuration.icon
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

#Preview {
    HouseholdView(model: .demo)
}

#Preview("Hebrew (RTL)") {
    HouseholdView(model: .demo)
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    HouseholdView(model: .demo)
        .preferredColorScheme(.dark)
}
