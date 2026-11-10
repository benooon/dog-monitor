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
            GeometryReader { proxy in
                form
                    // Keep the form a readable column on iPad instead of stretching edge to edge.
                    .contentMargins(.horizontal, DS.Layout.readableMargin(in: proxy.size.width), for: .scrollContent)
            }
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "Create household", isLoading: model.isWorking) {
                    Task {
                        await model.createHousehold(name: householdName, dogName: dogName.isEmpty ? nil : dogName)
                    }
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("create-household")
                .frame(maxWidth: DS.Layout.readableWidth)
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.l)
            }
            .background(Color(.systemGroupedBackground))
            .sensoryFeedback(.error, trigger: model.errorMessage) { _, new in new != nil }
            // Inline: the large title does not fit an iPhone width (or in Hebrew).
            .navigationTitle("Create your household")
            .navigationBarTitleDisplayMode(.inline)
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

    private var form: some View {
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
