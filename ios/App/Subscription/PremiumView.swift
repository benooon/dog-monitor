import DogMonitorCore
import StoreKit
import SwiftUI

/// Owner only: buy Premium (a month of clips, everyone watching, more cameras), or see and manage
/// the current subscription.
struct PremiumView: View {
    let model: SubscriptionModel
    /// The household's dog when there is exactly one, so the pitch can name it.
    var dogName: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var showsManage = false

    var body: some View {
        NavigationStack {
            Group {
                if let status = model.status, status.isPremium {
                    active(status)
                } else {
                    switch model.storeState {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .ready:
                        store
                    case .unavailable:
                        unavailable
                    }
                }
            }
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .manageSubscriptionsSheet(isPresented: $showsManage)
            .onChange(of: showsManage) { _, isShown in
                if !isShown { Task { await model.refresh() } }
            }
            .task { await model.refresh() }
            .task { await model.loadProducts() }
        }
    }

    private var store: some View {
        let model = model
        let householdId = model.householdId
        // The purchase modifiers wrap the inset too, so the lifetime purchase is tied to the
        // household and reported like a subscription.
        return storeView
            .storeButton(.hidden, for: .restorePurchases)
            .storeButton(.visible, for: .policies)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: DS.Spacing.s) {
                    if let lifetime = model.lifetimeProduct {
                        lifetimeOffer(lifetime)
                    }
                    restoreButton
                }
            }
            .inAppPurchaseOptions { _ in [.appAccountToken(householdId)] }
            .onInAppPurchaseCompletion { _, result in
                await model.handlePurchase(result)
            }
    }

    /// Lifetime Premium, after the subscriptions: one payment, no renewals.
    private func lifetimeOffer(_ product: Product) -> some View {
        ProductView(product) {
            Image(systemName: "infinity")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
        }
        .productViewStyle(.compact)
        .padding(.horizontal, DS.Spacing.l)
        .accessibilityIdentifier("premium-lifetime")
    }

    /// Uses the plans the model already loaded, so StoreKit doesn't show its own loading state again.
    @ViewBuilder
    private var storeView: some View {
        let locale = locale
        let layoutDirection = layoutDirection
        let dogName = dogName
        let subscriptions = model.subscriptionProducts
        if subscriptions.isEmpty {
            SubscriptionStoreView(productIDs: SubscriptionProducts.subscriptions) {
                PremiumHeader(dogName: dogName, locale: locale, layoutDirection: layoutDirection)
            }
        } else {
            SubscriptionStoreView(subscriptions: subscriptions) {
                PremiumHeader(dogName: dogName, locale: locale, layoutDirection: layoutDirection)
            }
        }
    }

    /// The App Store didn't return the plans. Restore stays reachable for people who already paid.
    private var unavailable: some View {
        ContentUnavailableView {
            Label("Premium isn't available right now", systemImage: "video.badge.plus")
        } description: {
            Text("Check your connection and try again in a moment.")
        } actions: {
            Button("Try again") {
                Task { await model.loadProducts() }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("premium-retry")
        }
        .safeAreaInset(edge: .bottom) { restoreButton }
    }

    private var restoreButton: some View {
        VStack(spacing: DS.Spacing.s) {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button {
                Task { await model.restore() }
            } label: {
                if model.isRestoring {
                    ProgressView()
                } else {
                    Text("Restore purchases")
                }
            }
            .font(.footnote)
            .disabled(model.isRestoring)
            .accessibilityIdentifier("premium-restore")
        }
        .padding(.bottom, DS.Spacing.s)
    }

    private func active(_ status: SubscriptionDTO) -> some View {
        List {
            Section {
                PremiumHeader(dogName: dogName, locale: locale, layoutDirection: layoutDirection)
                    .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Plan", value: status.isLifetime ? String(localized: "Premium for good") : String(localized: "Premium"))
                if !status.isLifetime, let expiresAt = status.expiresAt {
                    LabeledContent("Paid through") {
                        Text(expiresAt, format: .dateTime.day().month().year())
                    }
                }
                LabeledContent("Cameras") {
                    Text("\(status.usage.cameras) of \(status.limits.cameras)")
                }
            }
            Section {
                Button("Manage subscription", systemImage: "creditcard") { showsManage = true }
            } footer: {
                if status.isLifetime {
                    Text("Premium is yours for good. If a subscription is still running, cancel it here so it stops renewing.")
                } else {
                    Text("Change or cancel your plan in your App Store account.")
                }
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

/// The pitch, shared by the store and the "you're on Premium" screen, built from `PlanFeatures`.
/// StoreKit hosts its marketing content without our environment, so the locale and
/// layout direction are passed in and re-applied.
///
/// Only features that have shipped are listed: insights get their line when they exist
/// (DECISIONS 2026-11-11).
private struct PremiumHeader: View {
    let dogName: String?
    let locale: Locale
    let layoutDirection: LayoutDirection

    private let premium = PlanFeatures.premium

    var body: some View {
        content
            .environment(\.locale, locale)
            .environment(\.layoutDirection, layoutDirection)
    }

    private var content: some View {
        VStack(spacing: DS.Spacing.l) {
            VStack(spacing: DS.Spacing.s) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                title
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                feature("Clips are kept for \(premium.clipRetentionDays) days, not one.", systemImage: "film.stack")
                reelFeature
                feature("Everyone in the household watches.", systemImage: "person.3")
                feature("Up to \(premium.cameras) cameras.", systemImage: "video.badge.plus")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            freeAlerts
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.l)
    }

    private var title: Text {
        if let dogName {
            Text("Keep a month of \(dogName)'s moments")
        } else {
            Text("Keep a month of moments")
        }
    }

    private var reelFeature: some View {
        Label {
            Group {
                if let dogName {
                    Text("\(dogName)'s day in 30 seconds, ready to share.")
                } else {
                    Text("The day in 30 seconds, ready to share.")
                }
            }
            .foregroundStyle(.primary)
        } icon: {
            Image(systemName: "play.rectangle.on.rectangle")
                .foregroundStyle(.tint)
        }
        .font(.body)
    }

    private var freeAlerts: Text {
        if let dogName {
            Text("Alerts about \(dogName) stay free on every plan.")
        } else {
            Text("Dog alerts stay free on every plan.")
        }
    }

    private func feature(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(text)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .font(.body)
    }
}

#Preview {
    PremiumView(model: SubscriptionModel(api: DogMonitorAPI(baseURL: AppConfig.apiBaseURL), householdId: UUID()), dogName: "Rex")
}

#Preview("Hebrew (RTL)") {
    PremiumView(model: SubscriptionModel(api: DogMonitorAPI(baseURL: AppConfig.apiBaseURL), householdId: UUID()), dogName: "רקס")
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    PremiumView(model: SubscriptionModel(api: DogMonitorAPI(baseURL: AppConfig.apiBaseURL), householdId: UUID()))
        .preferredColorScheme(.dark)
}
