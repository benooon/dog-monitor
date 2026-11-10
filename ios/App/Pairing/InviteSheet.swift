import DogMonitorCore
import SwiftUI

/// Owner-only: a one-time invite as a QR code and 6-digit code, valid for 10 minutes.
/// New cameras scan it; family members type the code to join.
struct InviteSheet: View {
    let model: ViewerSessionModel

    @Environment(\.dismiss) private var dismiss
    @State private var invite: InviteDTO?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let invite {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        content(for: invite, now: context.date)
                    }
                } else if model.isWorking {
                    ProgressView()
                } else if let message = model.errorMessage {
                    Text(message).foregroundStyle(.red)
                    Button("Try again") { Task { await load() } }
                }
                Spacer()
                Text("On the new phone, choose Camera and scan this code, or type the 6 digits. Family members can join with the same code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func content(for invite: InviteDTO, now: Date) -> some View {
        let countdown = InviteCountdown(expiresAt: invite.expiresAt)
        if countdown.isExpired(at: now) {
            Text("This invite has expired.")
            Button("New invite") { Task { await load() } }
                .buttonStyle(.borderedProminent)
        } else {
            QRCodeImage(text: PairingCode.qrContent(token: invite.token))
                .frame(maxWidth: 260)
                .padding()
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
            // Digits read left to right in every language.
            Text(verbatim: "\(invite.code.prefix(3)) \(invite.code.suffix(3))")
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityIdentifier("invite-code")
            Text("Expires in \(countdown.label(at: now))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let link = model.inviteLink(for: invite) {
                ShareLink(item: link, message: Text("Join our household in Dog Monitor.")) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func load() async {
        invite = await model.createInvite()
    }
}
