import SwiftUI

struct StoreSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared
    @State private var showCreateStore = false
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
                    if viewModel.householdStores.isEmpty {
                        emptyStateView
                    } else {
                        storeList
                    }

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
                    .foregroundColor(DesignSystem.Colors.dillGreen)
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
                ForEach(viewModel.householdStores) { store in
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
                    .fill(DesignSystem.Colors.dillGreen.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [DesignSystem.Colors.dillGreen, DesignSystem.Colors.dillGreen.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: DesignSystem.Shadows.dillGreenGlow, radius: 8, x: 0, y: 4)
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
                            .tint(DesignSystem.Colors.dillGreen)
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
