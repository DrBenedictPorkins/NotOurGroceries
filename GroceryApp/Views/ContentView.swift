import SwiftUI

struct ContentView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @StateObject private var viewModel = ShoppingListViewModel()

    // Shopping status check state
    @State private var hasCheckedShoppingStatus = false
    @State private var showInfoModal = false
    @State private var isAtStoreMode = false

    var body: some View {
        ZStack {
            if isAtStoreMode {
                // Direct to AtStoreModeView when shopping is active
                AtStoreModeView(isPresented: $isAtStoreMode)
                    .environmentObject(viewModel)
                    .environmentObject(amplifyService)
            } else {
                // Normal TabView
                TabView {
                    ShoppingListView()
                        .tabItem {
                            Label("Shopping List", systemImage: "list.bullet")
                        }

                    StoresView()
                        .tabItem {
                            Label("Stores", systemImage: "building.2.fill")
                        }

                    HouseholdView()
                        .tabItem {
                            Label("Household", systemImage: "person.3.fill")
                        }

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape.fill")
                        }
                }
                .tint(DesignSystem.Colors.dillGreen)
                .metallicBackground()
                .environmentObject(viewModel)
                .environmentObject(amplifyService)
            }

            // Info modal overlay
            if showInfoModal {
                ShoppingActiveInfoModal(
                    isCurrentUserShopping: viewModel.isCurrentUserShopping,
                    shopperName: viewModel.activeShopperDisplayName,
                    storeName: shoppingStoreName,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showInfoModal = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isAtStoreMode)
        .task {
            await checkShoppingStatusOnLaunch()
        }
        .onChange(of: isAtStoreMode) { _, newValue in
            // When exiting shopping mode, sync the viewModel state
            if !newValue {
                viewModel.isAtStoreMode = false
            }
        }
    }

    // MARK: - Computed Properties

    private var shoppingStoreName: String? {
        guard let storeId = viewModel.shoppingStoreId else { return nil }
        return viewModel.householdStores.first(where: { $0.id == storeId })?.name
    }

    // MARK: - Shopping Status Check

    private func checkShoppingStatusOnLaunch() async {
        guard !hasCheckedShoppingStatus else { return }
        hasCheckedShoppingStatus = true

        // Load shopping list and stores first
        await viewModel.loadShoppingList()
        await viewModel.loadStores()

        // Check if shopping is active (either as shopper or remote member)
        let shouldRestoreShoppingMode = await viewModel.fetchHouseholdShoppingStatus()

        await MainActor.run {
            if viewModel.shoppingStatus == .atStore {
                // Shopping is active - show info modal
                if shouldRestoreShoppingMode {
                    // Current user is the shopper
                    viewModel.isAtStoreMode = true
                    isAtStoreMode = true
                }
                // Show info modal for both shopper and non-shopper
                withAnimation(.easeIn(duration: 0.3)) {
                    showInfoModal = true
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AmplifyService.shared)
}
