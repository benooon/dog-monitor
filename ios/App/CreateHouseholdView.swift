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
                        .accessibilityIdentifier("dog-name")
                } footer: {
                    Text("Family members and cameras join your household later with an invite.")
                }
                if let message = model.errorMessage {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task {
                            await model.createHousehold(name: householdName, dogName: dogName.isEmpty ? nil : dogName)
                        }
                    } label: {
                        HStack {
                            Text("Create")
                            if model.isWorking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("create-household")
                }
                Section("Join a household") {
                    TextField("Invite code", text: $inviteCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("invite-code-field")
                    Button("Join") {
                        Task { await model.joinHousehold(code: inviteCode) }
                    }
                    .disabled(PairingCode.parse(inviteCode) == nil || model.isWorking)
                }
            }
            .navigationTitle("Create your household")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out") { model.signOut() }
                }
            }
        }
    }
}
