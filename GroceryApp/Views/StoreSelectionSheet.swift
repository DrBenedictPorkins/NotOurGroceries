import SwiftUI

struct StoreSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared
    @State private var showCreateStore = false
    @State private var isStartingPlain = false
    var onStoreSelected: () -> Void

    // Batch mapping flow state
    @State private var selectedStore: HouseholdStore?
    @State private var unmappedItems: [GroceryItem] = []
    @State private var showBatchMapping = false
    @State private var showReadyToShop = false
    @State private var isCheckingMappings = false

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                VStack(spacing: 0) {
                    storeList

                    Spacer()

                    // Add New Store Button
                    addStoreButton
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("Select Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                }
            }
            .sheet(isPresented: $showCreateStore) {
                CreateStoreSheet()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $showBatchMapping) {
                if let store = selectedStore {
                    BatchAisleMappingSheet(
                        store: store,
                        unmappedItems: unmappedItems,
                        onComplete: {
                            // After batch mapping, show ready to shop
                            showReadyToShop = true
                        },
                        onCancel: {
                            // User cancelled, clear selection
                            selectedStore = nil
                            unmappedItems = []
                        }
                    )
                    .environmentObject(viewModel)
                }
            }
            .sheet(isPresented: $showReadyToShop) {
                if let store = selectedStore {
                    ReadyToShopSheet(
                        store: store,
                        onGo: {
                            // Enter shopping mode and dismiss
                            Task {
                                await viewModel.enterShoppingMode(store: store)
                            }
                            onStoreSelected()
                            dismiss()
                        },
                        onCancel: {
                            // User cancelled, clear selection
                            selectedStore = nil
                            unmappedItems = []
                        }
                    )
                }
            }
        }
    }

    // MARK: - Store List

    private var storeList: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Always first, and always available: shopping should never be
                // blocked behind naming a store or defining its aisles.
                justShoppingRow

                ForEach(viewModel.householdStores.filter { $0.name != ShoppingListViewModel.defaultStoreName }) { store in
                    StoreRow(store: store, isLoading: isCheckingMappings && selectedStore?.id == store.id) {
                        Task {
                            await handleStoreSelection(store)
                        }
                    }
                    .disabled(isCheckingMappings)
                }
            }
            .padding(.vertical, 20)
        }
    }

    /// Shop with no particular store. Backed by a plain no-aisle store created on
    /// first use, so items can still learn aisle positions over time if the user
    /// ever bothers to record them.
    private var justShoppingRow: some View {
        Button {
            Task { await startJustShopping() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bag.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(DesignSystem.Colors.neonCyan.opacity(0.14)))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Just shopping")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                    Text("No particular store, no aisles — just the list")
                        .font(.system(size: 12))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }

                Spacer(minLength: 0)

                if isStartingPlain {
                    ProgressView().scaleEffect(0.7).tint(DesignSystem.Colors.neonCyan)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(DesignSystem.Colors.neonCyan.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isCheckingMappings || isStartingPlain)
    }

    private func startJustShopping() async {
        isStartingPlain = true
        defer { isStartingPlain = false }

        let store: HouseholdStore?
        if let existing = viewModel.householdStores.first(where: { $0.name == ShoppingListViewModel.defaultStoreName }) {
            store = existing
        } else {
            store = await viewModel.createStore(
                name: ShoppingListViewModel.defaultStoreName,
                chain: nil,
                aisles: [],
                layoutType: .noAisles
            )
        }

        guard let store else { return }
        selectedStore = store
        unmappedItems = []
        showReadyToShop = true
    }

    // MARK: - Store Selection Flow

    private func handleStoreSelection(_ store: HouseholdStore) async {
        isCheckingMappings = true
        selectedStore = store

        // Stores with no aisles never need aisle mapping — go straight to ready-to-shop.
        guard !store.hasNoAisles else {
            unmappedItems = []
            isCheckingMappings = false
            showReadyToShop = true
            return
        }

        // Fetch mappings for this store
        _ = try? await storeService.fetchMappings(storeId: store.id)

        // Find unmapped items (same logic as AtStoreModeView)
        let unmapped = viewModel.shoppingList.filter { item in
            storeService.mapping(
                for: item.productId,
                normalizedName: item.normalizedName,
                in: store.id
            ) == nil
        }

        await MainActor.run {
            unmappedItems = unmapped
            isCheckingMappings = false

            if unmapped.isEmpty {
                // No unmapped items, go straight to ready to shop
                showReadyToShop = true
            } else {
                // Has unmapped items, show batch mapping first
                showBatchMapping = true
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.2")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.white.opacity(0.3))

            Text("No Stores Yet")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text("Add your first store to get started")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Add Store Button

    private var addStoreButton: some View {
        Button(action: {
            showCreateStore = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add New Store")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(DesignSystem.Colors.neonCyan.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [DesignSystem.Colors.neonCyan, DesignSystem.Colors.neonCyan.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: DesignSystem.Shadows.neonCyanGlow, radius: 8, x: 0, y: 4)
            )
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Store Row

private struct StoreRow: View {
    let store: HouseholdStore
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Store name
                    Text(store.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    // Loading or Chevron
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(DesignSystem.Colors.neonCyan)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }
                }

                HStack(spacing: 12) {
                    // Chain badge (if set)
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

                    // Aisle count
                    HStack(spacing: 4) {
                        Image(systemName: store.hasNoAisles ? "basket" : "list.bullet")
                            .font(.system(size: 11, weight: .medium))
                        Text(store.hasNoAisles ? "No aisles" : "\(store.aisleLayout.count) aisles")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                    .fill(DesignSystem.Colors.glassBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.lg)
                            .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    StoreSelectionSheet(onStoreSelected: {})
        .environmentObject(ShoppingListViewModel())
}
