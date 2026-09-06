import SwiftUI
import StoreKit

/// The one place a subscription can be bought.
///
/// Reached from the allowances page and the two allowance nudges, and nowhere
/// else — that constraint is the whole reason the free tier does not feel like a
/// demo. It is never reachable while a trip is running; the nudges enforce that
/// upstream, because asking for money mid-shop turns a limit into a hostage
/// situation. See MONETIZATION.qmd, "The nudge".
struct PaywallSheet: View {
    @ObservedObject private var store = StoreKitService.shared
    @Environment(\.dismiss) private var dismiss

    /// What the household is short of, so the sheet opens by answering the
    /// question the person actually arrived with rather than a generic pitch.
    let reason: String?

    init(reason: String? = nil) {
        self.reason = reason
    }

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

                ScrollView {
                    VStack(spacing: 24) {
                        header
                        if let reason { reasonCard(reason) }
                        whatYouGet
                        options
                        restoreRow
                        smallPrint
                    }
                    .padding(24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Not now") { dismiss() }
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await store.loadProducts() }
        // Dismiss on the real outcome — the server having marked the household
        // subscribed — not on the App Store sheet closing.
        .onChange(of: store.didEntitleHousehold) { _, entitled in
            if entitled { dismiss() }
        }
        .alert("Purchase", isPresented: Binding(
            get: { store.purchaseError != nil },
            set: { if !$0 { store.purchaseError = nil } }
        )) {
            Button("OK", role: .cancel) { store.purchaseError = nil }
        } message: {
            Text(store.purchaseError ?? "")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "cart.fill")
                .font(.system(size: 56))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .neonGlow(color: DesignSystem.Colors.dillGreen)

            Text("Lift your household's limits")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)
                .multilineTextAlignment(.center)

            // Said plainly and early, because whoever hit the limit may not be
            // whoever can pay, and the app has no way to know which one is
            // holding the phone.
            Text("One subscription covers everyone in your household.")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func reasonCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DesignSystem.Colors.neonAmber)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(DesignSystem.Colors.neonAmber.opacity(0.12))
            )
    }

    private var whatYouGet: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("infinite", "No cap on aisle placements or imports")
            benefit("person.3.fill", "As many people in the household as you like")
            benefit("list.bullet", "As many items and suggestions as you like")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(DesignSystem.Colors.cardBackground)
        )
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.dillGreen)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var options: some View {
        if store.isLoadingProducts {
            ProgressView().tint(DesignSystem.Colors.dillGreen).padding(.vertical, 24)
        } else if store.products.isEmpty {
            Text("Couldn't load the subscription options. Try again.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
        } else {
            VStack(spacing: 12) {
                ForEach(store.products, id: \.id) { product in
                    optionButton(product)
                }
            }
        }
    }

    private func optionButton(_ product: StoreKit.Product) -> some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text(product.priceWithPeriod)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                Spacer()
                if store.purchaseInFlight {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(DesignSystem.Colors.accentGradient)
            )
        }
        .disabled(store.purchaseInFlight)
    }

    /// Required by App Review, and needed by anyone who reinstalls or opens the
    /// app on a second device.
    private var restoreRow: some View {
        Button {
            Task { await store.restore() }
        } label: {
            Text("Restore purchases")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.dillGreen)
        }
        .disabled(store.purchaseInFlight)
    }

    private var smallPrint: some View {
        VStack(spacing: 8) {
            Text("Renews automatically until cancelled. Cancel any time in Settings › Apple Account › Subscriptions.")
            HStack(spacing: 16) {
                Link("Privacy", destination: AppIdentity.privacyPolicyURL)
                Link("Manage subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(DesignSystem.Colors.dillGreen)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(DesignSystem.Colors.textTertiary)
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }
}
