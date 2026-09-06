import SwiftUI

/// Modal shown after splash when shopping is active
/// Different visuals for shopper vs non-shopper
struct ShoppingActiveInfoModal: View {
    let isCurrentUserShopping: Bool
    let shopperName: String?
    let storeName: String?
    let onDismiss: () -> Void
    /// Claim the trip. Present whenever somebody else holds the shopper slot,
    /// because "someone else is shopping" and a lone OK button is a dead end when
    /// the person reading it is the one actually in the shop.
    var onTakeOver: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { } // Prevent tap-through

            // Modal card
            VStack(spacing: 20) {
                // Icon
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.15))
                        .frame(width: 80, height: 80)

                    Image(systemName: iconName)
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(accentColor)
                }

                // Title
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                // Subtitle (store info)
                if let storeName = storeName {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 14))
                        Text(storeName)
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                }

                // Description
                Text(description)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 8)

                // OK Button
                if !isCurrentUserShopping, let onTakeOver {
                    Button(action: onTakeOver) {
                        Text("I'm the one shopping")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(DesignSystem.Colors.dillGreen)
                            )
                    }
                    Text("Takes the trip over on this phone. \(shopperName ?? "They") will be told.")
                        .font(.system(size: 12))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .multilineTextAlignment(.center)
                }

                Button(action: {
                    onDismiss()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    Text("OK")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(accentGradient)
                                .shadow(color: accentColor.opacity(0.4), radius: 8, x: 0, y: 4)
                        )
                }
                .padding(.top, 8)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(DesignSystem.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(borderGradient, lineWidth: 1.5)
                    )
                    .shadow(color: accentColor.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Computed Properties

    private var iconName: String {
        isCurrentUserShopping ? "cart.fill" : "bell.badge.fill"
    }

    private var title: String {
        if isCurrentUserShopping {
            return "You're Shopping"
        } else {
            return "Shopping in Progress"
        }
    }

    /// Both of these described the request/approve inbox, which was removed —
    /// so the person not shopping was being told they could ask for items when
    /// in fact the list is simply locked, and the shopper was promised requests
    /// that would never arrive.
    private var description: String {
        if isCurrentUserShopping {
            return "Cross things off as you go, and add anything you spot. The list is locked for everyone else until you finish."
        } else {
            let name = shopperName ?? "Someone"
            return "\(name) is shopping, so the list is locked until they're done. If you need something, text them — they'll see that."
        }
    }

    private var accentColor: Color {
        isCurrentUserShopping ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.neonPink
    }

    private var accentGradient: LinearGradient {
        if isCurrentUserShopping {
            return LinearGradient(
                colors: [DesignSystem.Colors.dillGreen, DesignSystem.Colors.dillGreen.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [DesignSystem.Colors.neonPink, DesignSystem.Colors.neonPurple],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderGradient: LinearGradient {
        if isCurrentUserShopping {
            return LinearGradient(
                colors: [DesignSystem.Colors.dillGreen.opacity(0.5), DesignSystem.Colors.dillGreen.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [DesignSystem.Colors.neonPink.opacity(0.5), DesignSystem.Colors.neonPurple.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

#Preview("Shopper") {
    ShoppingActiveInfoModal(
        isCurrentUserShopping: true,
        shopperName: nil,
        storeName: "Stop & Shop",
        onDismiss: {}
    )
}

#Preview("Non-Shopper") {
    ShoppingActiveInfoModal(
        isCurrentUserShopping: false,
        shopperName: "Porkins",
        storeName: "Stop & Shop",
        onDismiss: {}
    )
}
