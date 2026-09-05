import SwiftUI

/// Where the household stands. Reached from the Plan row in Settings and from
/// the launch pop-up.
///
/// Two sections with the difference in the heading, not left to be inferred:
/// recurring allowances refill on their own, structural ones lift only when the
/// household subscribes. "12 placements left" and "1 member slot left" look the
/// same on a screen and mean entirely different things.
struct AllowancesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @ObservedObject private var allowances = AllowanceService.shared
    @ObservedObject private var userCache = UserCache.shared

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                DesignSystem.Colors.darkMetallicGradient.ignoresSafeArea().opacity(0.3)

                ScrollView {
                    VStack(spacing: 20) {
                        if let summary = allowances.summary {
                            planCard(summary)
                            recurringCard(summary)
                            structuralCard(summary)
                        } else {
                            ProgressView()
                                .tint(DesignSystem.Colors.dillGreen)
                                .padding(.top, 60)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Allowances")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
        }
        .task { await allowances.refresh() }
    }

    // MARK: - Plan

    private func planCard(_ summary: AllowanceSummary) -> some View {
        HStack {
            Text("Plan")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
            Spacer()
            Text(summary.plan.label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(summary.entitled ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.textSecondary)
        }
        .padding(20)
        .background(glassCard)
    }

    // MARK: - Recurring

    private func recurringCard(_ summary: AllowanceSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                icon: "arrow.clockwise",
                title: summary.entitled ? "This period" : "Resets in \(summary.daysUntilReset) day\(summary.daysUntilReset == 1 ? "" : "s")"
            )

            allowanceRow(
                title: "Aisle placements",
                detail: "Items placed in aisles when a trip starts",
                used: summary.placementsUsed,
                cap: summary.placementsCap,
                entitled: summary.entitled
            )
            allowanceRow(
                title: "Imports",
                detail: "Pasted, photographed or dictated lists",
                used: summary.parsesUsed,
                cap: summary.parsesCap,
                entitled: summary.entitled
            )
        }
        .padding(20)
        .background(glassCard)
    }

    // MARK: - Structural

    private func structuralCard(_ summary: AllowanceSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(
                icon: summary.entitled ? "lock.open" : "lock",
                title: summary.entitled ? "Unlocked" : "Lifts when you subscribe"
            )

            allowanceRow(
                title: "Household members",
                detail: nil,
                used: userCache.users.count,
                cap: summary.membersCap,
                entitled: summary.entitled
            )
            allowanceRow(
                title: "Items",
                detail: "List and suggestions together",
                used: viewModel.totalItemCount,
                cap: summary.itemsCap,
                entitled: summary.entitled
            )
        }
        .padding(20)
        .background(glassCard)
    }

    // MARK: - Pieces

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(DesignSystem.Colors.dillGreen)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
            Spacer()
        }
    }

    /// "62 of 100" while capped; just the count once the cap is lifted, because
    /// a denominator that no longer applies reads as a limit that still does.
    private func allowanceRow(title: String, detail: String?, used: Int, cap: Int, entitled: Bool) -> some View {
        let left = max(0, cap - used)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Spacer()
                // Clamped while capped — the soft cap lets the last request
                // overshoot, and "103 of 100" reads as a bug. Uncapped, the
                // real count is the interesting number.
                Text(entitled ? "\(used)" : "\(min(used, cap)) of \(cap)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundColor(entitled || left > 0 ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.warning)
            }
            if !entitled {
                ProgressView(value: Double(min(used, cap)), total: Double(max(cap, 1)))
                    .tint(left > 0 ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.warning)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
        }
    }

    private var glassCard: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(DesignSystem.Colors.glassBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
            )
    }
}
