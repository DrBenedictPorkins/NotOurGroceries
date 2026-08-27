import SwiftUI

/// A celebratory modal shown when shopping is completed
struct ShoppingCompletedSheet: View {
    let stats: ShoppingCompletionStats
    let onDismiss: () -> Void

    @State private var showConfetti = false
    @State private var animateStats = false

    var body: some View {
        ZStack {
            // Background
            DesignSystem.Colors.background
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Celebration icon
                celebrationHeader

                // Stats cards
                statsSection

                // Store info
                storeInfo

                Spacer()

                // Done button
                doneButton
            }
            .padding(24)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.2)) {
                showConfetti = true
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.3)) {
                animateStats = true
            }
        }
    }

    // MARK: - Celebration Header

    private var celebrationHeader: some View {
        VStack(spacing: 16) {
            // Checkmark with glow
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.success.opacity(0.2))
                    .frame(width: 120, height: 120)

                Circle()
                    .fill(DesignSystem.Colors.success.opacity(0.3))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)
                    .shadow(color: DesignSystem.Colors.success.opacity(0.5), radius: 10)
            }
            .scaleEffect(showConfetti ? 1.0 : 0.5)
            .opacity(showConfetti ? 1.0 : 0)

            Text("Shopping Complete!")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)
                .opacity(showConfetti ? 1.0 : 0)

            Text("Great job!")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .opacity(showConfetti ? 1.0 : 0)
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 16) {
            // Main stats row
            HStack(spacing: 16) {
                statCard(
                    icon: "cart.fill",
                    value: "\(stats.itemsPickedUp)",
                    label: "Picked Up",
                    color: DesignSystem.Colors.success
                )

                if stats.itemsNotPickedUp > 0 {
                    statCard(
                        icon: "xmark.circle",
                        value: "\(stats.itemsNotPickedUp)",
                        label: "Not found",
                        color: DesignSystem.Colors.warning
                    )
                }
            }

            // Secondary stats row
            HStack(spacing: 16) {
                statCard(
                    icon: "clock.fill",
                    value: stats.formattedDuration,
                    label: "Duration",
                    color: DesignSystem.Colors.neonCyan
                )

                statCard(
                    icon: "percent",
                    value: "\(stats.completionPercentage)%",
                    label: "Complete",
                    color: stats.completionPercentage == 100
                        ? DesignSystem.Colors.success
                        : DesignSystem.Colors.neonPurple
                )
            }

            // Custom items learned row (only show if > 0)
            if stats.customItemsLearned > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundColor(DesignSystem.Colors.neonCyan)

                    Text("\(stats.customItemsLearned) new item\(stats.customItemsLearned == 1 ? "" : "s") learned")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
                .padding(.top, 8)
            }
        }
        .opacity(animateStats ? 1.0 : 0)
        .offset(y: animateStats ? 0 : 20)
    }

    private func statCard(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Store Info

    private var storeInfo: some View {
        HStack(spacing: 8) {
            Image(systemName: "storefront")
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.textTertiary)

            Text(stats.storeName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)

            Text("•")
                .foregroundColor(DesignSystem.Colors.textTertiary)

            Text(formatTime(stats.startedAt))
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.textTertiary)

            Text("-")
                .foregroundColor(DesignSystem.Colors.textTertiary)

            Text(formatTime(stats.endedAt))
                .font(.system(size: 14))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .opacity(animateStats ? 1.0 : 0)
    }

    // MARK: - Done Button

    private var doneButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onDismiss()
        } label: {
            Text("Done")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(DesignSystem.Colors.accentGradient)
                )
        }
        .opacity(animateStats ? 1.0 : 0)
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    ShoppingCompletedSheet(
        stats: ShoppingCompletionStats(
            itemsPickedUp: 12,
            itemsNotPickedUp: 2,
            itemsAddedDuringTrip: 3,
            customItemsLearned: 2,
            storeName: "Trader Joe's",
            startedAt: Date().addingTimeInterval(-2700), // 45 min ago
            endedAt: Date()
        ),
        onDismiss: {}
    )
}
