import DogMonitorCore
import SwiftUI

/// Owner-only: a one-time invite as a QR code and 6-digit code, valid for 10 minutes.
/// New cameras scan it; family members type the code to join.
struct InviteSheet: View {
    let model: ViewerSessionModel

    @Environment(\.dismiss) private var dismiss
    @State private var invite: InviteDTO?
    @State private var showsPremium = false

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
                if let status = model.subscription?.status, status.suggestsUpgrade {
                    CameraLimitNotice { showsPremium = true }
                }
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
            .sheet(isPresented: $showsPremium) {
                if let subscription = model.subscription {
                    PremiumView(model: subscription)
                }
            }
            .task {
                await load()
                await model.subscription?.refresh()
            }
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

/// Shown when the free plan has no camera spot left. Family members can still join.
private struct CameraLimitNotice: View {
    let showPremium: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("New cameras need Premium. Family members can still join with this code.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Get Premium", action: showPremium)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("invite-get-premium")
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }
}
