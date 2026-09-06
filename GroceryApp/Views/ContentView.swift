import SwiftUI

struct ContentView: View {
    @EnvironmentObject var amplifyService: AmplifyService
    @StateObject private var viewModel = ShoppingListViewModel()

    // Shopping status check state
    @State private var hasCheckedShoppingStatus = false
    @State private var showInfoModal = false
    @State private var isAtStoreMode = false

    // The allowance pop-up. Shown on launch and on return to the foreground
    // after a long background, when half or more of a recurring allowance is
    // gone, and never while a trip is on — see MONETIZATION.qmd, "The nudge".
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var allowances = AllowanceService.shared
    @State private var backgroundedAt: Date?
    @State private var showAllowanceNudge = false
    @State private var showAllowances = false
    private static let longBackground: TimeInterval = 90 * 60

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

            // The allowance pop-up, same card and place as the shopping modal.
            if showAllowanceNudge, let summary = allowances.summary {
                AllowanceNudgeModal(
                    summary: summary,
                    onSeeAllowances: {
                        withAnimation(.easeOut(duration: 0.2)) { showAllowanceNudge = false }
                        showAllowances = true
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.2)) { showAllowanceNudge = false }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(99)
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
        // Presented here, above every list that shows a row. Owned by the row,
        // this sheet was torn down whenever the list rebuilt underneath it —
        // which is what saying an aisle out loud does, because the write
        // republishes the stores.
        .sheet(item: $viewModel.itemShowingDetail) { item in
            ItemDetailSheet(item: item)
                .environmentObject(viewModel)
        }
        // Deleting an item is confirmed here, above every list that shows one.
        // Owned by a row, this dialog was presented while the swipe collapsed and
        // the row was rebuilt underneath it — it flashed and its Delete fired on
        // its own. Delete is for an item that should not exist: a mis-heard
        // dictation, a typo. It is not "not this week", which is what tapping the
        // row does, and the message says so because both make the row disappear
        // and only one is recoverable.
        .confirmationDialog(
            viewModel.itemPendingDeletion.map { "Delete \($0.name)?" } ?? "Delete this item?",
            isPresented: Binding(
                get: { viewModel.itemPendingDeletion != nil },
                set: { if !$0 { viewModel.itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let doomed = viewModel.itemPendingDeletion else { return }
                viewModel.itemPendingDeletion = nil
                Task { await viewModel.deleteItem(doomed) }
            }
            Button("Cancel", role: .cancel) { viewModel.itemPendingDeletion = nil }
        } message: {
            Text("This removes it permanently. To keep it for next time, tap the item instead — it moves to suggestions.")
        }
        .task {
            await checkShoppingStatusOnLaunch()
            await refreshAllowancesAndMaybeNudge(showCard: true)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                // Refresh on every return so the feature gates are current; the
                // card only after a long time away.
                let longEnough = backgroundedAt.map { Date().timeIntervalSince($0) >= Self.longBackground } ?? false
                backgroundedAt = nil
                Task { await refreshAllowancesAndMaybeNudge(showCard: longEnough) }
            default:
                break
            }
        }
        .sheet(isPresented: $showAllowances) {
            AllowancesView()
                .environmentObject(viewModel)
        }
        .allowanceRefusal($viewModel.allowanceRefusal, viewModel: viewModel)
        // Attached here, not on the list screen, so it is seen whichever tab is
        // open. A list that has stopped tracking the household is not something
        // to mention quietly on one screen.
        .overlay {
            if !viewModel.stuckSyncNames.isEmpty {
                SyncStuckModal(
                    stuckNames: viewModel.stuckSyncNames,
                    onDiscardAndReload: {
                        Task { await viewModel.discardStuckChangesAndReload() }
                    },
                    onKeepTrying: { viewModel.stuckSyncNames = [] }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(98)
            }
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

    // MARK: - Allowances

    private func refreshAllowancesAndMaybeNudge(showCard: Bool) async {
        await allowances.refresh()
        guard showCard else { return }
        // The hard rule: never while at the store. `isAtStoreMode` covers the
        // shopper; `shoppingStatus` covers everyone else in the household.
        guard !isAtStoreMode, viewModel.shoppingStatus != .atStore else { return }
        guard let summary = allowances.summary, !summary.entitled else { return }
        let freshSignIn = allowances.showOnNextAppearance
        allowances.showOnNextAppearance = false
        if freshSignIn || summary.warrantsNudge {
            withAnimation(.easeIn(duration: 0.3)) { showAllowanceNudge = true }
        }
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
