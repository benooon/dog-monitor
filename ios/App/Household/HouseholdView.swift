import DogMonitorCore
import SwiftUI
import UIKit

/// Who and what is in the household: family members, cameras and phones. The owner can invite,
/// remove members and remove devices.
struct HouseholdView: View {
    let model: ViewerSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsInvite = false
    @State private var memberToRemove: MemberDTO?
    @State private var deviceToRemove: DeviceDTO?
    @State private var sharesTrainingData = false
    @State private var copiedExportKey = false

    private var household: HouseholdDTO? { model.household }
    private var isOwner: Bool { household?.role == .owner }

    var body: some View {
        NavigationStack {
            Group {
                if let household {
                    list(for: household)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: device.name)
                    if let detail = detail(now: context.date) {
                        Text(detail)
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

    private func detail(now: Date) -> LocalizedStringKey? {
        if device.role == .camera {
            return device.isOnline(now: now) ? "Online" : "Offline"
        }
        return ownerName.map { "\($0)'s phone" }
    }
}

#Preview {
    HouseholdView(model: ViewerSessionModel())
}

#Preview("Hebrew (RTL)") {
    HouseholdView(model: ViewerSessionModel())
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    HouseholdView(model: ViewerSessionModel())
        .preferredColorScheme(.dark)
}
