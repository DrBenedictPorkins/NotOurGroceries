import SwiftUI

/// Simple confirmation sheet before entering shopping mode
struct ReadyToShopSheet: View {
    @Environment(\.dismiss) private var dismiss

    let store: HouseholdStore
    let onGo: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Icon
            Image(systemName: "cart.fill")
                .font(.system(size: 72, weight: .thin))
                .foregroundColor(DesignSystem.Colors.dillGreen)

            // Title
            VStack(spacing: 12) {
                Text("Ready to Shop!")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text("You're about to start shopping at")
                    .font(.system(size: 16))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                Text(store.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)
            }

            Spacer()

            // Buttons
            VStack(spacing: 16) {
                // Let's Go button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onGo()
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cart.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Let's Go!")
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(DesignSystem.Colors.success)
                    )
                    .shadow(color: DesignSystem.Colors.success.opacity(0.4), radius: 8)
                }

                // Cancel button
                Button {
                    onCancel()
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                DesignSystem.Colors.background
                DesignSystem.Colors.darkMetallicGradient.opacity(0.3)
            }
            .ignoresSafeArea()
        )
    }
}

#Preview {
    ReadyToShopSheet(
        store: HouseholdStore(
            id: "1",
            householdId: "h1",
            name: "Stop & Shop",
            chain: "Stop & Shop",
            aisleLayout: []
        ),
        onGo: {},
        onCancel: {}
    )
}
