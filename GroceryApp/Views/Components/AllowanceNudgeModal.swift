import SwiftUI

/// The allowance pop-up, shown on launch and on return from a long background
/// when half or more of a recurring allowance is gone. Never while shopping —
/// see MONETIZATION.qmd, "The nudge". Same card as `ShoppingActiveInfoModal`,
/// because it appears in the same place for the same reason: something worth
/// knowing before you start, then out of the way.
struct AllowanceNudgeModal: View {
    let summary: AllowanceSummary
    /// Counted on the client, so it arrives separately from the summary.
    let itemsUsed: Int
    let onSeeAllowances: () -> Void
    let onDismiss: () -> Void

    private let accent = DesignSystem.Colors.neonAmber

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture { }

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(accent)
                }

                Text("Allowances")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                VStack(spacing: 12) {
                    row("Aisle placements", used: summary.placementsUsed, cap: summary.placementsCap)
                    row("Imports", used: summary.parsesUsed, cap: summary.parsesCap)
                    row("Items on the list", used: itemsUsed, cap: summary.itemsCap)
                }
                .padding(.vertical, 4)

                Text("Resets in \(summary.daysUntilReset) day\(summary.daysUntilReset == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onSeeAllowances()
                } label: {
                    Text("See allowances")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(LinearGradient(
                                    colors: [accent, accent.opacity(0.7)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ))
                                .shadow(color: accent.opacity(0.4), radius: 8, x: 0, y: 4)
                        )
                }
                .padding(.top, 4)

                Button("OK", action: onDismiss)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(DesignSystem.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(LinearGradient(
                                colors: [accent.opacity(0.5), accent.opacity(0.2)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ), lineWidth: 1.5)
                    )
                    .shadow(color: accent.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 32)
        }
    }

    /// One line per allowance: the name, then the numbers in bold. Nothing else
    /// — this is read in the second before it is dismissed.
    private func row(_ title: String, used: Int, cap: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Spacer()
            // Clamped: the soft cap lets the last request overshoot, and "103 / 100"
            // reads as a bug rather than as "you are out".
            Text("\(min(used, cap)) / \(cap)")
                .font(.system(size: 20, weight: .bold).monospacedDigit())
                .foregroundColor(used >= cap ? DesignSystem.Colors.warning : .white)
        }
    }
}

#Preview {
    AllowanceNudgeModal(
        summary: AllowanceSummary(
            plan: .free, entitled: false, periodResetsAt: Date().addingTimeInterval(12 * 86_400),
            placementsUsed: 99, placementsCap: 100, parsesUsed: 2, parsesCap: 3, membersCap: 2, itemsCap: 150
        ),
        itemsUsed: 138,
        onSeeAllowances: {}, onDismiss: {}
    )
}
