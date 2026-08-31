import SwiftUI
import UIKit

/// "At The Store" mode view with aisle-based grouping and progress tracking
struct AtStoreModeView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @EnvironmentObject var amplifyService: AmplifyService
    @ObservedObject private var storeService = StoreService.shared
    @State private var showDoneShoppingAlert = false
    @State private var searchText = ""
    @State private var showStoreSwitcher = false
    @State private var showAisleManagement = false
    @FocusState private var searchFieldFocused: Bool
    @StateObject private var dictation = SpeechDictationService()

    // Get the currently selected household store (using shoppingStoreId when in shopping mode)
    private var selectedHouseholdStore: HouseholdStore? {
        if let shoppingStoreId = viewModel.shoppingStoreId {
            return storeService.householdStores.first { $0.id == shoppingStoreId }
        }
        return storeService.householdStores.first
    }

    // Real aisle groups from product mappings (simple productId lookup)
    // Uses direct productId lookup - LLM handles normalization when adding items
    private var aisleGroups: [AisleGroup] {
        guard let store = selectedHouseholdStore else {
            // Fallback: nothing to sort against, so everything is unsorted
            return [AisleGroup(
                id: "unmapped",
                displayName: "ALL ITEMS",
                items: viewModel.shoppingList,
                displayOrder: 0
            )]
        }

        // Grouped by what the aisle is *called*, not by the id it is stored
        // under. Mappings for one shop accumulate under several ids that mean the
        // same place — a plain "Produce" written by one path and
        // "standard-produce" written by another — and keying on the id put the
        // same aisle on screen twice, once with two items and once with one.
        var groups: [String: [GroceryItem]] = [:]
        /// A representative id per name, kept so the display order can still be
        /// looked up. An id the store's own layout knows about wins, because that
        /// is the one carrying a real position in the walk.
        var idForName: [String: String] = [:]

        for item in viewModel.shoppingList {
            // Look up by productId first, then normalizedName
            if let mapping = storeService.mapping(for: item.productId, normalizedName: item.normalizedName, in: store.id) {
                let aisleId = mapping.effectiveAisle
                let name = AisleNaming.displayName(for: aisleId, in: store.aisleLayout)

                groups[name, default: []].append(item)

                let knownToLayout = store.aisleLayout.contains {
                    $0.id == aisleId || $0.name == aisleId || $0.number == aisleId
                }
                if idForName[name] == nil || knownToLayout {
                    idForName[name] = aisleId
                }
            }
            // Items without a match are handled by unmappedItems
        }

        // Build AisleGroup array directly from the groups dictionary (NOT from store.aisleLayout)
        // This ensures we show aisles that have mapped items, regardless of aisleLayout
        let result: [AisleGroup] = groups.map { (name, items) in
            let aisleId = idForName[name] ?? name

            // Display order from the store's own layout, falling back to the
            // built-in section order so a shop with no scanned aisles still walks
            // produce first and frozen last instead of collapsing to zero.
            let displayOrder = store.aisleLayout.first(where: { $0.id == aisleId || $0.name == aisleId || $0.number == aisleId })?.displayOrder
                ?? StoreService.standardSections.first(where: { $0.id == aisleId || $0.name.caseInsensitiveCompare(name) == .orderedSame })?.displayOrder
                ?? 0

            return AisleGroup(
                id: aisleId,
                displayName: name.uppercased(),
                items: items,
                displayOrder: displayOrder
            )
        }.sorted { group1, group2 in
            // Sort by display order first, then by aisle ID (numeric then alpha)
            if group1.displayOrder != group2.displayOrder {
                return group1.displayOrder < group2.displayOrder
            }
            // Numeric aisles come first
            let num1 = Int(group1.id)
            let num2 = Int(group2.id)
            if let n1 = num1, let n2 = num2 { return n1 < n2 }
            if num1 != nil { return true }
            if num2 != nil { return false }
            return group1.id < group2.id
        }

        return result
    }

    /// Format aisle display name from aisle ID
    private func formatAisleDisplayName(_ aisleId: String, store: HouseholdStore) -> String {
        AisleNaming.headerName(for: aisleId, in: store.aisleLayout)
    }

    // Store unmapped items separately for the custom items section
    // Items are unmapped if they have no mapping for this store (by productId or normalizedName)
    private var unmappedItems: [GroceryItem] {
        guard let store = selectedHouseholdStore else {
            return []
        }

        // Find items without any aisle mapping
        return viewModel.shoppingList.filter { item in
            storeService.mapping(for: item.productId, normalizedName: item.normalizedName, in: store.id) == nil
        }
    }

    private var totalItemsCount: Int {
        viewModel.shoppingList.count + viewModel.inCart.count
    }

    private var checkedItemsCount: Int {
        viewModel.inCart.count
    }

    private var progressPercentage: CGFloat {
        guard totalItemsCount > 0 else { return 0 }
        return CGFloat(checkedItemsCount) / CGFloat(totalItemsCount)
    }

    /// Determines if the current toast notification is from another user
    private var isOtherUserAction: Bool {
        guard !viewModel.toastUserName.isEmpty else { return false }
        guard let userId = amplifyService.currentUser?.userId else { return true }
        let currentUserName = UserCache.shared.displayName(for: userId)
        return viewModel.toastUserName != currentUserName
    }

    var body: some View {
        ZStack {
            // Background gradient
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            VStack(spacing: 0) {
                // Header
                headerView

                // Progress indicator
                progressView

                // Search Bar - active shopper can add items directly
                SearchBar(
                    text: $searchText,
                    isFocused: $searchFieldFocused,
                    onSubmit: addItemFromSearch,
                    onProductSelected: addProductFromSearch,
                    onVoice: toggleVoiceCapture,
                    isListening: dictation.isRecording
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

                // Store layout list
                List {
                    // Items without aisle mapping (unknown location) - shown FIRST for immediate resolution
                    if !unmappedItems.isEmpty {
                        Section {
                            ForEach(unmappedItems) { item in
                                GroceryItemRow(item: item)
                                    .environmentObject(viewModel)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        } header: {
                            unmappedHeader
                        }
                        .listSectionSeparator(.hidden)
                    }

                    // Aisle groups
                    ForEach(aisleGroups) { aisleGroup in
                        Section {
                            // Items in this aisle
                            ForEach(aisleGroup.items) { item in
                                GroceryItemRow(item: item)
                                    .environmentObject(viewModel)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        } header: {
                            aisleHeader(aisleGroup)
                        }
                        .listSectionSeparator(.hidden)
                    }

                    // In Cart section - always visible (even when empty)
                    Section {
                        if viewModel.inCart.isEmpty {
                            emptyInCartPlaceholder
                                .listRowBackground(inCartSectionBackground)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        } else {
                            ForEach(viewModel.inCart) { item in
                                GroceryItemRow(item: item)
                                    .environmentObject(viewModel)
                            }
                            .listRowBackground(inCartSectionBackground)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        }
                    } header: {
                        inCartHeader
                    }
                    .listSectionSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            // Glowing border overlay to indicate active shopping
            shoppingActiveBorderOverlay
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showStoreSwitcher) {
            StoreSwitcherSheet(currentStoreId: selectedHouseholdStore?.id)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showAisleManagement) {
            if let store = selectedHouseholdStore {
                StoreAisleManagementView(store: store)
                    .environmentObject(viewModel)
            }
        }
        .sheet(isPresented: $viewModel.showShoppingCompletedSheet) {
            if let stats = viewModel.shoppingCompletionStats {
                ShoppingCompletedSheet(stats: stats) {
                    viewModel.showShoppingCompletedSheet = false
                    viewModel.shoppingCompletionStats = nil
                    isPresented = false
                }
                .interactiveDismissDisabled()
            }
        }
        .confirmationDialog(
            uncrossedTitle,
            isPresented: $showDoneShoppingAlert,
            titleVisibility: .visible
        ) {
            // Two genuinely different situations, so make the user say which:
            // the store didn't have it, or they just stopped ticking things off.
            Button("Keep them on the list") {
                Task { await viewModel.exitShoppingMode(discardUncrossed: false) }
            }
            Button("Clear them", role: .destructive) {
                Task { await viewModel.exitShoppingMode(discardUncrossed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep them if the store didn't have them and you still need them — they'll be waiting on your list next time. Clear them if you actually got them and didn't tick them off.")
        }
    }

    private var uncrossedTitle: String {
        let n = viewModel.shoppingList.count
        return "\(n) item\(n == 1 ? "" : "s") still on your list"
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .top) {
            // Left side: Store name + action icons
            VStack(alignment: .leading, spacing: 12) {
                // Tappable store name - opens store switcher
                Button(action: {
                    showStoreSwitcher = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    HStack(spacing: 4) {
                        Text(selectedHouseholdStore?.name ?? "Select Store")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(DesignSystem.Colors.accentGradient)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.dillGreen)
                    }
                }

                // Action icons row (gear + inbox)
                HStack(spacing: 12) {
                    // Gear icon for aisle management
                    Button(action: {
                        showAisleManagement = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.1))
                            )
                    }

                }
            }

            Spacer()

            // Right side: username + Done Shopping button
            VStack(alignment: .trailing, spacing: 12) {
                // Logged-in user label
                if let userId = amplifyService.currentUser?.userId {
                    Text(UserCache.shared.displayName(for: userId))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary.opacity(0.7))
                }

                // Done Shopping button - prominent with accent color
                Button(action: {
                    if !viewModel.shoppingList.isEmpty {
                        showDoneShoppingAlert = true
                    } else {
                        Task {
                            await viewModel.exitShoppingMode(discardUncrossed: false)
                        }
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Done")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(DesignSystem.Colors.success.opacity(0.3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(DesignSystem.Colors.success, lineWidth: 1.5)
                            )
                    )
                    .shadow(color: DesignSystem.Colors.success.opacity(0.3), radius: 8, x: 0, y: 4)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 16)
    }

    // MARK: - Progress View

    private var progressView: some View {
        VStack(spacing: 12) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)

                    // Progress fill
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignSystem.Colors.accentGradient)
                        .frame(
                            width: geometry.size.width * progressPercentage,
                            height: 8
                        )
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: progressPercentage)
                }
            }
            .frame(height: 8)

            // Progress text or notification subtitle
            HStack {
                StatusSubtitleView(
                    defaultStatus: "\(checkedItemsCount)/\(totalItemsCount) items",
                    isShowingNotification: viewModel.showToast,
                    notificationMessage: viewModel.toastMessage,
                    notificationUserName: viewModel.toastUserName,
                    notificationType: viewModel.toastType,
                    isOtherUser: isOtherUserAction
                )

                Spacer()

                if let undoItem = viewModel.undoCartItem {
                    Button {
                        Task { await viewModel.undoMoveToCart() }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Undo \(undoItem.name)")
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.neonPink.opacity(0.3))
                                .overlay(Capsule().stroke(DesignSystem.Colors.neonPink.opacity(0.6), lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Text("\(Int(progressPercentage * 100))%")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DesignSystem.Colors.dillGreen)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.undoCartItem?.id)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Section Headers

    private func aisleHeader(_ aisleGroup: AisleGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DesignSystem.Colors.dillGreen)

            Text(aisleGroup.displayName.uppercased())
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DesignSystem.Colors.dillGreen)
                .tracking(1.2)

            Spacer()

            // Item count for this aisle
            Text("\(aisleGroup.items.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
    }

    /// A store with nothing to sort against has nothing to map, so unmapped items
    /// aren't an error state — they're just the list. Show a neutral header
    /// instead of the pink "unknown" warning.
    private var storeHasNoAisles: Bool {
        !(selectedHouseholdStore?.supportsAisleNavigation ?? false)
    }

    private var unmappedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: storeHasNoAisles ? "cart.fill" : "questionmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(storeHasNoAisles ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.neonPink)

                // Not "UNKNOWN AISLE" — that claims there is an aisle whose name
                // we have lost. These items simply have not been placed yet, and
                // the header should say so rather than invent a mystery.
                Text(storeHasNoAisles ? "TO GET" : "NOT SORTED YET")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(storeHasNoAisles ? DesignSystem.Colors.dillGreen : DesignSystem.Colors.neonPink)
                    .tracking(1.2)

                Spacer()

                Text("\(unmappedItems.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            if !storeHasNoAisles {
                Text("Long-press an item to say which aisle it's in")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
    }

    private var inCartHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.success)

                Text("IN CART")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.success)
                    .tracking(1.2)

                Spacer()

                Text("\(viewModel.inCart.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            Text("Tap items to restore to list")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
    }

    private var emptyInCartPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "cart")
                .font(.system(size: 32, weight: .thin))
                .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.5))

            Text("No items yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)

            Text("Cross off items as you shop")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.7))
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shopping Active Border Overlay

    private var shoppingActiveBorderOverlay: some View {
        RoundedRectangle(cornerRadius: 0)
            .stroke(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.dillGreen.opacity(0.6),
                        DesignSystem.Colors.neonPurple.opacity(0.4)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 3
            )
            .ignoresSafeArea()
            .shadow(color: DesignSystem.Colors.dillGreen.opacity(0.5), radius: 10)
            .allowsHitTesting(false)
    }

    // MARK: - Search Actions

    /// Add item from typed input - active shopper adds directly
    /// Tap to talk, tap to stop. The transcript lands in the search field rather
    /// than being added blind — mishearing "toothpaste" as "toast" and silently
    /// adding it is worse than making the user glance before hitting return.
    private func toggleVoiceCapture() {
        if dictation.isRecording {
            dictation.stop()
            return
        }
        dictation.onCommit = { text in
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            searchText = cleaned
            searchFieldFocused = true
        }
        Task {
            if case .granted = dictation.authState {
                dictation.start()
            } else {
                await dictation.requestAuth()
                if case .granted = dictation.authState { dictation.start() }
            }
        }
    }

    private func addItemFromSearch() {
        let itemName = searchText.trimmingCharacters(in: .whitespaces)
        guard !itemName.isEmpty else { return }
        searchText = ""
        searchFieldFocused = false

        Task {
            await viewModel.addItem(name: itemName)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Add item selected from product dropdown
    private func addProductFromSearch(_ product: Product) {
        searchText = ""
        searchFieldFocused = false
        Task {
            await viewModel.addItem(name: product.name, productId: product.id)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Section Backgrounds

    /// Subtle background for In Cart section
    private var inCartSectionBackground: some View {
        DesignSystem.Colors.success.opacity(0.03)
    }

    // MARK: - Helper Methods

    /// One rule for aisle headers, shared with every other screen.
    ///
    /// This used to have its own copy, which joined the number to the whole name
    /// — and a scanned aisle's name is a sample of the sign's contents, so the
    /// headers ran to three lines: "12 - SYRUP, TEA BAGS, CHOCOLATE SYRUP…".
    private func aisleHeaderName(_ aisle: StoreAisle) -> String {
        AisleNaming.headerName(for: aisle.id, in: [aisle])
    }

    /// Assign an item to a specific aisle in the store
    private func assignItemToAisle(item: GroceryItem, aisleId: String, store: HouseholdStore) async {
        do {
            try await storeService.assignProductToAisle(
                productId: item.productId,
                normalizedName: item.normalizedName,
                storeId: store.id,
                aisleId: aisleId
            )

            // Find the aisle name for feedback
            if let aisle = store.aisleLayout.first(where: { $0.id == aisleId || $0.name == aisleId || $0.number == aisleId }) {
                await MainActor.run {
                    viewModel.toastMessage = "Assigned to Aisle \(aisle.number)"
                    viewModel.toastType = .success
                    viewModel.showToast = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        } catch {
            await MainActor.run {
                viewModel.toastMessage = "Failed to assign aisle"
                viewModel.toastType = .error
                viewModel.showToast = true
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}

// MARK: - Shake Effect Modifier

// MARK: - Aisle Group Model

struct AisleGroup: Identifiable {
    let id: String
    let displayName: String
    let items: [GroceryItem]
    let displayOrder: Int
}

// MARK: - Preview

#Preview {
    AtStoreModeView(isPresented: .constant(true))
        .environmentObject(ShoppingListViewModel())
        .environmentObject(AmplifyService.shared)
}
