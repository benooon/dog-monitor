import DogMonitorCore
import SwiftUI

struct CreateHouseholdView: View {
    let model: ViewerSessionModel
    @State private var householdName = ""
    @State private var dogName = ""
    @State private var inviteCode = ""

    private var canSubmit: Bool {
        HouseholdNameRules.validated(householdName) != nil && !model.isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Household name", text: $householdName)
                        .textContentType(.organizationName)
                        .accessibilityIdentifier("household-name")
                    TextField("Dog's name (optional)", text: $dogName)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("dog-name")
                } footer: {
                    Text("Family members and cameras join your household later with an invite.")
                }
                if let message = model.errorMessage {
                    Section {
                        Label {
                            Text(verbatim: message)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                    }
                }
                Section("Join a household") {
                    TextField("Invite code", text: $inviteCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("invite-code-field")
                    Button("Join") {
                        Task { await model.joinHousehold(code: inviteCode) }
                    }
                    .accessibilityIdentifier("join-household")
                    .disabled(PairingCode.parse(inviteCode) == nil || model.isWorking)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Create household", isLoading: model.isWorking) {
                    Task {
                        await model.createHousehold(name: householdName, dogName: dogName.isEmpty ? nil : dogName)
                    }
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("create-household")
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.l)
            }
            .sensoryFeedback(.error, trigger: model.errorMessage) { _, new in new != nil }
            .navigationTitle("Create your household")
            .onChange(of: DeepLinkRouter.shared.pendingInvite, initial: true) { _, token in
                // Opened from an invite link: fill in the invite so one tap joins.
                guard let token else { return }
                inviteCode = token
                DeepLinkRouter.shared.pendingInvite = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out") { model.signOut() }
                }
            }
        }
    }
}

#Preview {
    CreateHouseholdView(model: ViewerSessionModel())
}

#Preview("Hebrew (RTL)") {
    CreateHouseholdView(model: ViewerSessionModel())
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    CreateHouseholdView(model: ViewerSessionModel())
        .preferredColorScheme(.dark)
}
