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
                ForEach(viewModel.storesInPickingOrder) { store in
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

            // A store with no layout has nowhere to put anything, so there is
            // nothing to ask the model and no tokens to spend. Shop the list as
            // it was typed — At Store already heads it "TO GET" when nothing is
            // mapped.
            if unmapped.isEmpty || store.aisleLayout.isEmpty {
                showReadyToShop = true
            } else {
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
            StoreCard(store: store, isLoading: isLoading)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    StoreSelectionSheet(onStoreSelected: {})
        .environmentObject(ShoppingListViewModel())
}
