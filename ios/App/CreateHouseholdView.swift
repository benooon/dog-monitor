import DogMonitorCore
import SwiftUI

struct CreateHouseholdView: View {
    let model: ViewerSessionModel
    @State private var householdName = ""
    @State private var inviteCode = ""
    /// The live key from an opened invite link, kept with the token it came with.
    @State private var inviteKey: (token: String, key: LiveKey)?
    /// The household the invite leads to, asked about before joining.
    @State private var pendingJoin: InvitePreviewDTO?
    @State private var isConfirmingJoin = false

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
                        // The dog gets its own steps right after ("Meet your dog").
                        await model.createHousehold(name: householdName, dogName: nil)
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
                // Opened from an invite link: fill in the invite and ask "Join <household>?" right away.
                guard let token else { return }
                inviteCode = token
                inviteKey = DeepLinkRouter.shared.pendingLiveKey.map { (token, $0) }
                DeepLinkRouter.shared.pendingInvite = nil
                DeepLinkRouter.shared.pendingLiveKey = nil
                Task { await reviewInvite() }
            }
            .alert(
                joinTitle,
                isPresented: $isConfirmingJoin,
                presenting: pendingJoin
            ) { _ in
                Button("Join") {
                    Task { await model.joinHousehold(code: inviteCode, liveKey: liveKeyForInvite) }
                }
                .accessibilityIdentifier("confirm-join-household")
                Button("Cancel", role: .cancel) {}
            } message: { preview in
                if let inviter = preview.inviter.firstName {
                    Text("Invited by \(inviter).")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign out") { model.signOut() }
                }
                ToolbarItem(placement: .bottomBar) {
                    DeleteAccountButton(model: model)
                }
            }
        }
    }

    /// The link's key, only while the field still holds that link's invite.
    private var liveKeyForInvite: LiveKey? {
        guard let inviteKey, PairingCode.parse(inviteCode) == inviteKey.token else { return nil }
        return inviteKey.key
    }

    private var joinTitle: Text {
        Text("Join \(pendingJoin?.household.name ?? "")?")
    }

    /// Shows which household the invite is for; joining waits for the person to confirm.
    private func reviewInvite() async {
        guard let preview = await model.previewInvite(code: inviteCode) else { return }
        // Kept after the alert closes so its title doesn't change while it animates away.
        pendingJoin = preview
        isConfirmingJoin = true
    }

    private var form: some View {
        Form {
            Section {
                TextField("Household name", text: $householdName)
                    .textContentType(.organizationName)
                    .accessibilityIdentifier("household-name")
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
                    Task { await reviewInvite() }
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
