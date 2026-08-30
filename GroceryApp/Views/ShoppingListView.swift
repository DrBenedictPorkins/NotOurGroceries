import SwiftUI

struct ShoppingListView: View {
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @EnvironmentObject var amplifyService: AmplifyService
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastBackgroundTime: Date?
    @State private var searchText = ""
    @State private var isAtStore = false
    @State private var showStoreSelection = false
    @State private var isCrossedOffExpanded = true
    @State private var isInCartExpanded = true
    @FocusState private var searchFieldFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showBulkImport = false
    @State private var showForceFinishAlert = false
    @State private var showForceFinishHoldSheet = false
    @State private var showQuickList = false
    @State private var showListMenu = false
    @State private var hintOn = false
    @State private var hasHinted = false
    @AppStorage("hasOpenedListMenu") private var hasOpenedListMenu = false

    var body: some View {
        ZStack {
            // Background gradient
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            VStack(spacing: 0) {
                // Custom Header
                headerView

                reconnectingLine

                // Offline is a condition, not a mode: everything still works, it
                // just isn't syncing. One line, not a screen and not a dialog.
                if viewModel.isOffline {
                    HStack(spacing: 7) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 12, weight: .semibold))
                        Text(offlineLine)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(DesignSystem.Colors.neonAmber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesignSystem.Colors.neonAmber.opacity(0.12))
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                // Sort Options - show when list has items, or keep visible while undo is pending
                if !viewModel.shoppingList.isEmpty || viewModel.undoSuggestionItem != nil {
                    sortOptionsBar
                }

                // List content
                ScrollViewReader { proxy in
                    List {
                        // Search bar
                        Section {
                            SearchBar(
                                text: $searchText,
                                isFocused: $searchFieldFocused,
                                onSubmit: addItemFromSearch,
                                onProductSelected: addProductFromSearch,
                                onImport: { showBulkImport = true }
                            )
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))

                        // Top anchor
                        Color.clear
                            .frame(height: 1)
                            .id("listTop")
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())

                        // All active items
                        Section {
                            if viewModel.shoppingList.isEmpty {
                                emptyStateView
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            } else {
                                ForEach(viewModel.shoppingList) { item in
                                    GroceryItemRow(item: item)
                                        .environmentObject(viewModel)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                        .transition(.asymmetric(
                                            insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.95))
                                        ))
                                }
                                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.shoppingList.map(\.id))
                            }
                        }
                        .listSectionSeparator(.hidden)

                        // In Cart Section - visible to non-active shoppers during active shopping
                        if viewModel.isSomeoneElseShopping {
                            Section {
                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        isInCartExpanded.toggle()
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }) {
                                    HStack {
                                        sectionHeader(
                                            title: "IN CART (\(viewModel.inCart.count))",
                                            icon: "checkmark.circle.fill",
                                            color: DesignSystem.Colors.dillGreen
                                        )
                                        Spacer()
                                        Image(systemName: isInCartExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(DesignSystem.Colors.dillGreen)
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))

                                if isInCartExpanded {
                                    if viewModel.inCart.isEmpty {
                                        inCartEmptyState
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                    } else {
                                        ForEach(viewModel.inCart) { item in
                                            InCartItemRow(item: item)
                                                .listRowBackground(Color.clear)
                                                .listRowSeparator(.hidden)
                                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                                        }
                                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.inCart.map(\.id))
                                    }
                                }
                            }
                            .listSectionSeparator(.hidden)
                        }

                        // Suggestions Section (collapsible) - visible for everyone
                        if !viewModel.suggestions.isEmpty {
                            Section {
                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        isCrossedOffExpanded.toggle()
                                    }
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }) {
                                    HStack {
                                        sectionHeader(
                                            title: "SUGGESTIONS (\(viewModel.suggestions.count))",
                                            icon: "lightbulb.fill",
                                            color: DesignSystem.Colors.neonAmber
                                        )
                                        Spacer()
                                        Image(systemName: isCrossedOffExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(DesignSystem.Colors.neonAmber)
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(suggestionsSectionBackground)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))

                                if isCrossedOffExpanded {
                                    ForEach(viewModel.suggestions) { item in
                                        GroceryItemRow(item: item)
                                            .environmentObject(viewModel)
                                            .listRowBackground(suggestionsSectionBackground)
                                            .listRowSeparator(.hidden)
                                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                            .transition(.asymmetric(
                                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .opacity.combined(with: .scale(scale: 0.95))
                                            ))
                                    }
                                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.suggestions.map(\.id))
                                }
                            }
                            .listSectionSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await viewModel.refreshAllData()
                    }
                    .onAppear {
                        scrollProxy = proxy
                    }
                }
            }

            // Glowing border overlay when shopping is active
            if viewModel.isSomeoneElseShopping {
                shoppingActiveBorderOverlay
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $isAtStore) {
            AtStoreModeView(isPresented: $isAtStore)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showStoreSelection) {
            StoreSelectionSheet(onStoreSelected: {
                // After store is selected, show At Store mode
                viewModel.isAtStoreMode = true
                isAtStore = true
            })
            .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: $showQuickList) {
            QuickListView(isPresented: $showQuickList)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showBulkImport) {
            BulkImportSheet(isPresented: $showBulkImport)
                .environmentObject(viewModel)
        }
        .alert("Force finish shopping?", isPresented: $showForceFinishAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                showForceFinishHoldSheet = true
            }
        } message: {
            let name = viewModel.activeShopperDisplayName ?? "The shopper"
            let elapsed = viewModel.shoppingElapsedDescription ?? "a while"
            Text("\(name) started shopping \(elapsed) ago and hasn't finished. Items in the cart will be moved back to the list.")
        }
        .sheet(isPresented: $showForceFinishHoldSheet) {
            ForceFinishHoldSheet(
                isPresented: $showForceFinishHoldSheet,
                shopperName: viewModel.activeShopperDisplayName ?? "the shopper",
                elapsed: viewModel.shoppingElapsedDescription ?? ""
            ) {
                Task { await viewModel.forceFinishAbandonedSession() }
            }
            .presentationDetents([.height(320)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showListMenu) {
            ListMenuSheet(
                isPresented: $showListMenu,
                onAtStore: { showStoreSelection = true },
                onQuickList: { showQuickList = true }
            )
            .environmentObject(viewModel)
            .environmentObject(amplifyService)
            .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.lockInteractionsOnWakeup()
                // Only refresh if backgrounded > 30 seconds
                if let lastTime = lastBackgroundTime,
                   Date().timeIntervalSince(lastTime) > 30 {
                    Task { await viewModel.refreshAllData() }
                }
            } else if newPhase == .background {
                lastBackgroundTime = Date()
            }
        }
        .onChange(of: viewModel.isSomeoneElseShopping) { _, isShopping in
            if isShopping {
                viewModel.startAbandonedCheckTimer()
            } else {
                viewModel.stopAbandonedCheckTimer()
            }
        }
        .onAppear {
            if viewModel.isSomeoneElseShopping {
                viewModel.startAbandonedCheckTimer()
            }
        }
        .onDisappear {
            viewModel.stopAbandonedCheckTimer()
        }
        // Note: Initial data loading and shopping status check is handled by ContentView
        // This view only needs to handle user-initiated "At Store" mode entry
    }

    // MARK: - Header View

    /// Title only. It is also the control — everything that used to crowd this
    /// row now lives one tap away, behind the chevron.
    private var headerView: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                hasOpenedListMenu = true
                showListMenu = true
            } label: {
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(headlineStyle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        statusLine
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.dillGreen.opacity(hintOn ? 0.16 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DesignSystem.Colors.dillGreen.opacity(hintOn ? 0.5 : 0), lineWidth: 1.5)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            shareButton

            // Primary action stays visible. The other modes live in the title
            // panel — nothing here for a thumb to confuse it with.
            if canStartShopping {
                atStoreButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 60)
        .padding(.bottom, 10)
        .onAppear(perform: runHintIfNeeded)
    }

    /// Nobody mid-session, and something to actually go and buy. Starting a trip
    /// with an empty list puts you in aisle-sorted shopping mode with no aisles
    /// and nothing to cross off.
    private var canStartShopping: Bool {
        viewModel.shoppingStatus == .idle && !viewModel.shoppingList.isEmpty
    }

    /// Hand the list to someone who is not in the household.
    ///
    /// Sits between the title and At Store, and simply is not there when there
    /// is nothing to send — the title is left-anchored and At Store is pinned
    /// right, so it appearing and disappearing moves neither of them.
    @ViewBuilder
    private var shareButton: some View {
        if !viewModel.shoppingList.isEmpty || !viewModel.inCart.isEmpty {
            ShareLink(
                item: ShareText.shoppingList(
                    active: viewModel.shoppingList,
                    inCart: viewModel.inCart,
                    storeName: viewModel.selectedHouseholdStore?.name
                )
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
    }

    private var atStoreButton: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showStoreSelection = true
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("At Store")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.dillGreen.opacity(0.15))
                    .overlay(
                        Capsule().stroke(
                            LinearGradient(
                                colors: [DesignSystem.Colors.dillGreen,
                                         DesignSystem.Colors.dillGreen.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                    )
                    .shadow(color: DesignSystem.Shadows.dillGreenGlow, radius: 8, x: 0, y: 4)
            )
        }
    }

    /// Pulses the title a few times the first time you land here, so the chevron
    /// isn't the only thing telling you it's tappable. Stops for good once used.
    private func runHintIfNeeded() {
        guard !hasOpenedListMenu, !hasHinted else { return }
        hasHinted = true

        Task { @MainActor in
            for _ in 0..<3 {
                withAnimation(.easeInOut(duration: 0.45)) { hintOn = true }
                try? await Task.sleep(nanoseconds: 500_000_000)
                withAnimation(.easeInOut(duration: 0.45)) { hintOn = false }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }
    }

    private var offlineLine: String {
        if let savedAt = viewModel.localSnapshotSavedAt {
            return "Offline · your list as of \(LocalListStore.savedAtDescription(savedAt)) · changes saved here"
        }
        return "Offline · changes saved on this phone"
    }

    /// The one line that changes with what's actually happening.
    private var headline: String {
        if viewModel.isSomeoneElseShopping {
            return "\(viewModel.activeShopperDisplayName ?? "Someone") is shopping"
        }
        if viewModel.shoppingList.isEmpty { return "Nothing to buy" }
        return "Shopping list"
    }

    private var headlineStyle: AnyShapeStyle {
        if viewModel.isSomeoneElseShopping {
            return AnyShapeStyle(DesignSystem.Colors.dillGreen)
        }
        return AnyShapeStyle(DesignSystem.Colors.textPrimary)
    }

    /// Quiet "still trying" line so the user knows the app hasn't given up.
    @ViewBuilder
    private var reconnectingLine: some View {
        if viewModel.isRetryingConnection {
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(DesignSystem.Colors.textTertiary)
                Text("Reconnecting…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    /// What the line under the headline says at rest.
    private var idleStatusText: String {
        if viewModel.isSomeoneElseShopping {
            let done = viewModel.inCart.count
            let total = done + viewModel.shoppingList.count
            let store = viewModel.householdStores.first(where: { $0.id == viewModel.shoppingStoreId })?.name
            let where_ = store.map { "at \($0)" } ?? "shopping"
            return total > 0 ? "\(where_) · \(done) of \(total) in cart" : where_
        }
        if viewModel.shoppingList.isEmpty {
            // Short enough to survive the At Store button sharing this row.
            return "Add your first item"
        }
        // Nothing useful to report — say nothing rather than count what's visible.
        return ""
    }

    // MARK: - Compact Shopping Status Line

    private var shoppingStatusLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cart.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.neonPink)

                if let shopperName = viewModel.activeShopperDisplayName {
                    Text(shopperName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.neonPink)
                }

                Text("is shopping")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)

                if let storeId = viewModel.shoppingStoreId,
                   let store = viewModel.householdStores.first(where: { $0.id == storeId }) {
                    Text("at")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                    Text(store.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.neonPurple)
                }

                Spacer()
            }

            if viewModel.isSessionAbandoned {
                abandonedSessionBanner
            }
        }
        .padding(.top, 4)
    }

    private var abandonedSessionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.neonAmber)

            VStack(alignment: .leading, spacing: 2) {
                Text("Session idle \(viewModel.shoppingElapsedDescription ?? "")")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                Text("Looks abandoned — you can end it")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            Button(action: {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showForceFinishAlert = true
            }) {
                Text("Force finish")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesignSystem.Colors.neonPink.opacity(0.25))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(DesignSystem.Colors.neonPink, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.neonAmber.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystem.Colors.neonAmber.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Shopping Active Border Overlay

    private var shoppingActiveBorderOverlay: some View {
        RoundedRectangle(cornerRadius: 0)
            .stroke(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.neonPink.opacity(0.6),
                        DesignSystem.Colors.neonPurple.opacity(0.4)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 3
            )
            .ignoresSafeArea()
            .shadow(color: DesignSystem.Colors.neonPink.opacity(0.5), radius: 10)
            .allowsHitTesting(false)
    }

    // MARK: - In Cart Empty State

    private var inCartEmptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "cart")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing in cart yet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                Text("Items will appear here as they're picked up")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textTertiary.opacity(0.7))
            }

            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - Status Line (notifications / item count)

    private var statusLine: some View {
        ZStack(alignment: .leading) {
            // Reports only what the eye can't already see. Counting items you
            // are looking at is noise; progress mid-trip is not.
            Text(idleStatusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .opacity(viewModel.showToast ? 0 : 1)

            // Notification message - shown when toast active
            if viewModel.showToast, !viewModel.toastMessage.isEmpty {
                HStack(spacing: 6) {
                    // Type icon for errors/warnings
                    if viewModel.toastType != .success {
                        Image(systemName: viewModel.toastType.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(viewModel.toastType.accentColor)
                    }

                    if !viewModel.toastUserName.isEmpty {
                        Text(viewModel.toastUserName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(viewModel.toastType.accentColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(viewModel.toastMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(toastMessageColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.showToast)
        .onChange(of: viewModel.showToast) { oldValue, newValue in
            print("STATUS LINE: showToast changed from \(oldValue) to \(newValue), message: '\(viewModel.toastMessage)'")
        }
    }

    /// Color for toast message based on type
    private var toastMessageColor: Color {
        switch viewModel.toastType {
        case .success:
            return DesignSystem.Colors.textSecondary
        case .error:
            return viewModel.toastType.accentColor.opacity(0.9)
        case .warning:
            return viewModel.toastType.accentColor.opacity(0.85)
        case .info:
            return DesignSystem.Colors.textSecondary
        }
    }

    /// Subtle background for Suggestions section
    private var suggestionsSectionBackground: some View {
        DesignSystem.Colors.neonAmber.opacity(0.03)
    }

    // MARK: - Sort Options Bar

    private var sortOptionsBar: some View {
        HStack(spacing: 8) {
            if let undoItem = viewModel.undoSuggestionItem {
                Spacer()
                Button {
                    Task { await viewModel.undoMoveToSuggestion() }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Undo \(undoItem.name)")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.neonPink.opacity(0.2))
                            .overlay(Capsule().stroke(DesignSystem.Colors.neonPink.opacity(0.6), lineWidth: 1.5))
                    )
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
            // Recent button
            sortButton(for: .recentFirst)

            // Combined A-Z / Z-A toggle button
            Button(action: {
                // Toggle between A-Z and Z-A, or activate A-Z if currently on Recent
                if viewModel.currentSort == .aToZ {
                    viewModel.setSort(.zToA)
                } else {
                    viewModel.setSort(.aToZ)
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: viewModel.currentSort == .zToA ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(viewModel.currentSort == .zToA ? "Z-A" : "A-Z")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(isAlphabeticalSort ? .white : DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isAlphabeticalSort
                              ? DesignSystem.Colors.dillGreen.opacity(0.3)
                              : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isAlphabeticalSort
                                ? DesignSystem.Colors.dillGreen.opacity(0.5)
                                : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer()
            } // end else (sort buttons)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .animation(.easeInOut(duration: 0.2), value: viewModel.undoSuggestionItem?.id)
    }

    private var isAlphabeticalSort: Bool {
        viewModel.currentSort == .aToZ || viewModel.currentSort == .zToA
    }

    private func sortButton(for option: SortOption) -> some View {
        Button(action: {
            viewModel.setSort(option)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            HStack(spacing: 4) {
                Image(systemName: option.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(option.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(viewModel.currentSort == option ? .white : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(viewModel.currentSort == option
                          ? DesignSystem.Colors.dillGreen.opacity(0.3)
                          : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(viewModel.currentSort == option
                            ? DesignSystem.Colors.dillGreen.opacity(0.5)
                            : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)

            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
                .tracking(1.2)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cart")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.white.opacity(0.3))

            Text("Your list is empty")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text("Add items using the search bar above")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Actions

    /// Add item from typed input - always custom since user typed something specific
    private func addItemFromSearch() {
        let itemName = searchText.trimmingCharacters(in: .whitespaces)
        guard !itemName.isEmpty else { return }
        searchText = ""
        searchFieldFocused = false

        Task {
            // Typed input is always custom - if user wanted a community product,
            // they would select from the autocomplete dropdown
            await viewModel.addItem(name: itemName)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Add item selected from product dropdown (always community item)
    private func addProductFromSearch(_ product: Product) {
        searchText = ""
        searchFieldFocused = false
        Task {
            await viewModel.addItem(name: product.name, productId: product.id)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - In Cart Item Row (Read-only for non-active shoppers)

/// A simple, read-only row showing an item that's been put in the cart
private struct InCartItemRow: View {
    let item: GroceryItem

    var body: some View {
        HStack(spacing: 12) {
            // Checkmark indicator
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.dillGreen)

            // Item name with strikethrough
            Text(item.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .strikethrough(true, color: DesignSystem.Colors.textTertiary)

            Spacer()

            // Quantity if present
            if let quantity = item.quantity, !quantity.isEmpty {
                Text(quantity)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.05))
                    )
            }

        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystem.Colors.dillGreen.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

#Preview {
    ShoppingListView()
        .environmentObject(ShoppingListViewModel())
        .environmentObject(AmplifyService.shared)
}

// MARK: - Force Finish Hold-to-Confirm Sheet

private struct ForceFinishHoldSheet: View {
    @Binding var isPresented: Bool
    let shopperName: String
    let elapsed: String
    let onConfirm: () -> Void

    private let holdDuration: TimeInterval = 2.0
    @State private var progress: CGFloat = 0
    @State private var isHolding: Bool = false
    @State private var didConfirm: Bool = false
    @State private var holdTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.neonAmber)
                .padding(.top, 12)

            VStack(spacing: 6) {
                Text("Force finish shopping")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                Text("\(shopperName) started \(elapsed) ago. Hold the button to confirm — items in the cart will move back to the list.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer(minLength: 0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(DesignSystem.Colors.neonPink.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(DesignSystem.Colors.neonPink, lineWidth: 1.5)
                    )

                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 14)
                        .fill(DesignSystem.Colors.neonPink.opacity(0.45))
                        .frame(width: geo.size.width * progress)
                }
                .allowsHitTesting(false)

                HStack(spacing: 8) {
                    Image(systemName: isHolding ? "hourglass" : "hand.tap.fill")
                    Text(isHolding ? "Keep holding…" : "Hold to end session")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
            }
            .frame(height: 54)
            .padding(.horizontal, 20)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHolding, !didConfirm else { return }
                        isHolding = true
                        withAnimation(.linear(duration: holdDuration)) {
                            progress = 1.0
                        }
                        holdTask?.cancel()
                        holdTask = Task {
                            try? await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
                            if Task.isCancelled || didConfirm { return }
                            didConfirm = true
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onConfirm()
                            isPresented = false
                        }
                    }
                    .onEnded { _ in
                        guard !didConfirm else { return }
                        holdTask?.cancel()
                        holdTask = nil
                        withAnimation(.easeOut(duration: 0.15)) {
                            progress = 0
                        }
                        isHolding = false
                    }
            )

            Button("Cancel") {
                isPresented = false
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textSecondary)
            .padding(.bottom, 12)
        }
        .padding(.vertical, 8)
        .presentationBackground(DesignSystem.Colors.background)
    }
}
