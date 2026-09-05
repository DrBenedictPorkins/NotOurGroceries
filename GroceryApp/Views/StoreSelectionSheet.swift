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

    /// The allowance warning at the "I'm at the store" tap — before the state
    /// flips, which is what keeps it inside the never-while-shopping rule. The
    /// cap is soft: a trip that starts with anything left is mapped in full.
    enum PlacementWarning: Identifiable {
        case lastOnes(uses: Int, left: Int)
        case exhausted(resetsInDays: Int)
        var id: String {
            switch self {
            case .lastOnes: return "last"
            case .exhausted: return "exhausted"
            }
        }
    }
    @State private var placementWarning: PlacementWarning?

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
                            Task { await AllowanceService.shared.refresh() }
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
            .alert(item: $placementWarning) { warning in
                switch warning {
                case .lastOnes(let uses, let left):
                    return Alert(
                        title: Text("Last of your aisle placements"),
                        message: Text("This trip places \(uses) items and uses the rest of your \(left) for this period. After it, trips shop unsorted until the allowance resets."),
                        primaryButton: .default(Text("Continue")) { showBatchMapping = true },
                        secondaryButton: .cancel { selectedStore = nil; unmappedItems = [] }
                    )
                case .exhausted(let days):
                    return Alert(
                        title: Text("Out of aisle placements"),
                        message: Text("This trip shops unsorted — new items go under TO GET. Placements reset in \(days) day\(days == 1 ? "" : "s")."),
                        primaryButton: .default(Text("Shop anyway")) { showReadyToShop = true },
                        secondaryButton: .cancel { selectedStore = nil; unmappedItems = [] }
                    )
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
        // And where the household stands, so the warning below is current.
        await AllowanceService.shared.refresh()

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
                return
            }

            // What this trip is about to spend, against what is left. At zero
            // the mapping sheet is skipped and the trip shops unsorted; on the
            // last ones the user is told before, not after.
            if let allowance = AllowanceService.shared.summary, !allowance.entitled {
                if allowance.placementsLeft == 0 {
                    placementWarning = .exhausted(resetsInDays: allowance.daysUntilReset)
                    return
                }
                if unmapped.count >= allowance.placementsLeft {
                    placementWarning = .lastOnes(uses: unmapped.count, left: allowance.placementsLeft)
                    return
                }
            }
            showBatchMapping = true
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
