import SwiftUI

/// One store, as a card.
///
/// Stores and Select Store used to carry a copy each. They drifted: the small
/// shop treatment went into one of them and the other went on saying
/// "0 sections", which reads as a store nobody finished setting up. There is one
/// card now, so anything true of a store is said the same way wherever it
/// appears.
///
/// The only thing that differs between the two screens is what sits on the right
/// — a chevron, or a spinner while the store is being opened. Wrapping is the
/// caller's job: Stores puts this inside a NavigationLink, Select Store inside a
/// Button.
struct StoreCard: View {
    let store: HouseholdStore
    var isLoading: Bool = false

    /// A shop with nowhere to walk to. Keyed off the layout, not off the name,
    /// because that is the actual difference — the seeded Deli/Bodega and a
    /// store somebody stripped the departments from are the same thing, and the
    /// card should say so for both.
    private var isSmallShop: Bool { store.aisleLayout.isEmpty }

    private var sectionSummary: String {
        if isSmallShop { return "Small shop — no aisles or departments" }
        let count = store.aisleLayout.count
        return "\(count) section\(count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(DesignSystem.Colors.dillGreen)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }

            HStack(spacing: 12) {
                if let chain = store.chain, !chain.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2")
                            .font(.system(size: 11, weight: .medium))
                        Text(chain)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.neonPurple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignSystem.Colors.neonPurple.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(DesignSystem.Colors.neonPurple.opacity(0.3), lineWidth: 1)
                    )
                }

                HStack(spacing: 4) {
                    Image(systemName: isSmallShop ? "bag.fill" : "list.bullet")
                        .font(.system(size: 11, weight: .medium))
                    Text(sectionSummary)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(isSmallShop ? DesignSystem.Colors.neonAmber
                                 : DesignSystem.Colors.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                .fill(isSmallShop
                      ? DesignSystem.Colors.neonAmber.opacity(0.07)
                      : DesignSystem.Colors.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                        .stroke(isSmallShop
                                ? DesignSystem.Colors.neonAmber.opacity(0.45)
                                : DesignSystem.Colors.glassBorder,
                                lineWidth: 1)
                )
        )
    }
}
