import DogMonitorCore
import StoreKit
import SwiftUI

/// Owner only: buy Premium (more cameras), or see and manage the current subscription.
struct PremiumView: View {
    let model: SubscriptionModel

    @Environment(\.dismiss) private var dismiss
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
        return SubscriptionStoreView(productIDs: SubscriptionProducts.all) {
            PremiumHeader()
        }
        .storeButton(.hidden, for: .restorePurchases)
        .storeButton(.visible, for: .policies)
        .inAppPurchaseOptions { _ in [.appAccountToken(householdId)] }
        .onInAppPurchaseCompletion { _, result in
            await model.handlePurchase(result)
        }
        .safeAreaInset(edge: .bottom) { restoreButton }
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
                PremiumHeader()
                    .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Plan", value: String(localized: "Premium"))
                if let expiresAt = status.expiresAt {
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
                Text("Change or cancel your plan in your App Store account.")
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

/// The pitch, shared by the store and the "you're on Premium" screen.
private struct PremiumHeader: View {
    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "video.badge.plus")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Watch every room")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Premium lets your household pair up to \(SubscriptionProducts.premiumCameraLimit) cameras.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Spacing.l)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PremiumView(model: SubscriptionModel(api: DogMonitorAPI(baseURL: AppConfig.apiBaseURL), householdId: UUID()))
}

#Preview("Hebrew (RTL)") {
    PremiumView(model: SubscriptionModel(api: DogMonitorAPI(baseURL: AppConfig.apiBaseURL), householdId: UUID()))
        .environment(\.locale, Locale(identifier: "he"))
        .environment(\.layoutDirection, .rightToLeft)
}

#Preview("Dark") {
    PremiumView(model: SubscriptionModel(api: DogMonitorAPI(baseURL: AppConfig.apiBaseURL), householdId: UUID()))
        .preferredColorScheme(.dark)
}
