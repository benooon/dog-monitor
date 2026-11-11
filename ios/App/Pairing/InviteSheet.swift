import DogMonitorCore
import SwiftUI

/// Owner-only: a one-time invite as a QR code and 6-digit code, valid for 10 minutes.
/// New cameras scan it; family members type the code to join.
struct InviteSheet: View {
    let model: ViewerSessionModel

    @Environment(\.dismiss) private var dismiss
    @State private var invite: InviteDTO?
    @State private var loadFailed = false
    /// Bumped on every failed attempt so each one gets its own haptic.
    @State private var failures = 0
    @State private var showsPremium = false

    /// Keeps the invite readable on iPad instead of stretching across the sheet.
    private static var contentMaxWidth: CGFloat { 400 }
    /// The QR code stays large enough to scan from arm's length, never wider than this.
    private static var codeMaxWidth: CGFloat { 240 }

    /// - Parameter invite: An invite to show right away (previews); otherwise one is created on appear.
    init(model: ViewerSessionModel, invite: InviteDTO? = nil) {
        self.model = model
        _invite = State(initialValue: invite)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.xxl) {
                    if let invite {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            content(for: invite, now: context.date)
                        }
                    } else if loadFailed {
                        ContentUnavailableView {
                            Label("Couldn't create an invite.", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Check your connection and try again.")
                        } actions: {
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView()
                            .padding(.vertical, DS.Spacing.section)
                    }

                    if let status = model.subscription?.status, status.suggestsUpgrade {
                        CameraLimitNotice { showsPremium = true }
                    }
                }
                .frame(maxWidth: Self.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Spacing.xl)
                .padding(.vertical, DS.Spacing.xxl)
            }
            .sensoryFeedback(.error, trigger: failures)
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showsPremium) {
                if let subscription = model.subscription {
                    PremiumView(model: subscription, dogName: model.household?.soleDogName)
                }
            }
            .task {
                if invite == nil {
                    await load()
                }
                await model.subscription?.refresh()
            }
        }
    }

    @ViewBuilder
    private func content(for invite: InviteDTO, now: Date) -> some View {
        let countdown = InviteCountdown(expiresAt: invite.expiresAt)
        if countdown.isExpired(at: now) {
            ContentUnavailableView {
                Label("This invite has expired.", systemImage: "clock.badge.xmark")
            } actions: {
                Button("New invite") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: DS.Spacing.l) {
                QRCodeImage(text: PairingCode.qrContent(token: invite.token, liveKey: model.liveKey))
                    .frame(maxWidth: Self.codeMaxWidth)
                    .padding(DS.Spacing.l)
                    // QR codes need dark modules on a light field to scan, in dark mode too.
                    .background(.white, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .accessibilityElement()
                    .accessibilityLabel(Text("Invite QR code"))
                    .accessibilityAddTraits(.isImage)

                VStack(spacing: DS.Spacing.xs) {
                    // Digits read left to right in every language.
                    Text(verbatim: "\(invite.code.prefix(3)) \(invite.code.suffix(3))")
                        .font(.largeTitle.weight(.semibold))
                        .fontDesign(.monospaced)
                        .monospacedDigit()
                        .environment(\.layoutDirection, .leftToRight)
                        .textSelection(.enabled)
                        .accessibilityLabel(Text("Invite code"))
                        // One digit at a time, so VoiceOver doesn't read "one hundred twenty-three".
                        .accessibilityValue(Text(verbatim: invite.code.map { String($0) }.joined(separator: " ")))
                        .accessibilityIdentifier("invite-code")
                    Text("Expires in \(countdown.label(at: now))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Text("On the new phone, choose Camera and scan this code, or type the 6 digits. Family members can join with the same code.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let link = model.inviteLink(for: invite) {
                ShareLink(item: link, message: Text("Join our household in Dog Monitor.")) {
                    Label("Share invite link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    private func load() async {
        loadFailed = false
        invite = nil
        invite = await model.createInvite()
        if invite == nil {
            loadFailed = true
            failures += 1
        }
    }
}

/// Shown when the free plan has no camera spot left. Family members can still join.
private struct CameraLimitNotice: View {
    let showPremium: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            Text("New cameras need Premium. Family members can still join with this code.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Get Premium", action: showPremium)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("invite-get-premium")
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.l)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous))
    }
}

private extension InviteDTO {
    /// A fresh sample invite for previews.
    static var preview: InviteDTO {
        InviteDTO(token: "preview-token", code: "482913", expiresAt: .now.addingTimeInterval(9 * 60 + 42))
    }
}

#Preview {
    InviteSheet(model: ViewerSessionModel(), invite: .preview)
}

#Preview("Hebrew (RTL)") {
    InviteSheet(model: ViewerSessionModel(), invite: .preview)
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    InviteSheet(model: ViewerSessionModel(), invite: .preview)
        .preferredColorScheme(.dark)
}

#Preview("Expired") {
    InviteSheet(
        model: ViewerSessionModel(),
        invite: InviteDTO(token: "preview-token", code: "482913", expiresAt: .now.addingTimeInterval(-60))
    )
}
