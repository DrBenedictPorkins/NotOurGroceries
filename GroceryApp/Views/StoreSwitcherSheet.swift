import SwiftUI
import UIKit

/// Sheet for switching stores mid-shopping
struct StoreSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared

    let currentStoreId: String?

    var body: some View {
        NavigationView {
            ZStack {
                // Background
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                VStack(spacing: 0) {
                    if storeService.householdStores.isEmpty {
                        emptyStateView
                    } else {
                        storeListView
                    }
                }
            }
            .navigationTitle("Switch Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                }
            }
        }
    }

    // MARK: - Store List

    private var storeListView: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(storeService.householdStores) { store in
                    StoreSwitcherRow(
                        store: store,
                        isCurrentStore: store.id == currentStoreId
                    ) {
                        Task {
                            await switchToStore(store)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "building.2")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.white.opacity(0.3))

            Text("No Stores Available")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text("Add stores in the settings to switch between them")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Actions

    private func switchToStore(_ store: HouseholdStore) async {
        // Call viewModel.switchStore() when implemented
        await viewModel.switchStore(store)
        await MainActor.run {
            dismiss()
        }
    }
}

// MARK: - Store Switcher Row

private struct StoreSwitcherRow: View {
    let store: HouseholdStore
    let isCurrentStore: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            if !isCurrentStore {
                action()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }) {
            HStack(spacing: 16) {
                // Store icon
                ZStack {
                    Circle()
                        .fill(
                            isCurrentStore
                                ? DesignSystem.Colors.neonCyan.opacity(0.2)
                                : DesignSystem.Colors.glassBackground
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "building.2")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(
                            isCurrentStore
                                ? DesignSystem.Colors.neonCyan
                                : DesignSystem.Colors.textSecondary
                        )
                }

                // Store info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(store.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)

                        if isCurrentStore {
                            Text("CURRENT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(DesignSystem.Colors.neonCyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(DesignSystem.Colors.neonCyan.opacity(0.2))
                                )
                        }
                    }

                    HStack(spacing: 12) {
                        // Chain badge
                        if let chain = store.chain, !chain.isEmpty {
                            Text(chain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                        }

                        // Aisle count
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 10, weight: .medium))
                            Text("\(store.aisleLayout.count) aisles")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                    }
                }

                Spacer()

                // Selection indicator
                if isCurrentStore {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(DesignSystem.Colors.neonCyan)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                    .fill(
                        isCurrentStore
                            ? DesignSystem.Colors.neonCyan.opacity(0.05)
                            : DesignSystem.Colors.glassBackground
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                            .stroke(
                                isCurrentStore
                                    ? DesignSystem.Colors.neonCyan.opacity(0.5)
                                    : DesignSystem.Colors.glassBorder,
                                lineWidth: isCurrentStore ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(isCurrentStore ? 0.8 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    StoreSwitcherSheet(currentStoreId: "store1")
        .environmentObject(ShoppingListViewModel())
}
