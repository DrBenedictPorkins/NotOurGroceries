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

                // Search Bar
                SearchBar(
                    text: $searchText,
                    isFocused: $searchFieldFocused,
                    onSubmit: addItemFromSearch,
                    onProductSelected: addProductFromSearch
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // Sort Options
                sortOptionsBar

                // List content
                ScrollViewReader { proxy in
                    List {
                        // Top anchor for scroll-to-top
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
                                }
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
                                            color: DesignSystem.Colors.neonCyan
                                        )
                                        Spacer()
                                        Image(systemName: isInCartExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(DesignSystem.Colors.neonCyan)
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
                                        }
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
                                            color: DesignSystem.Colors.neonYellow
                                        )
                                        Spacer()
                                        Image(systemName: isCrossedOffExpanded ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(DesignSystem.Colors.neonYellow)
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
                                    }
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Only refresh if backgrounded > 30 seconds
                if let lastTime = lastBackgroundTime,
                   Date().timeIntervalSince(lastTime) > 30 {
                    Task { await viewModel.refreshAllData() }
                }
            } else if newPhase == .background {
                lastBackgroundTime = Date()
            }
        }
        // Note: Initial data loading and shopping status check is handled by ContentView
        // This view only needs to handle user-initiated "At Store" mode entry
    }

    // MARK: - Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shopping List")
                        .font(.system(size: 32, weight: .bold, design: .default))
                        .foregroundStyle(DesignSystem.Colors.accentGradient)

                    // Inline notification / item count
                    statusLine
                }

                Spacer()

                // Right side: username label + At Store button
                VStack(alignment: .trailing, spacing: 8) {
                    // Logged-in user label
                    if let userId = amplifyService.currentUser?.userId {
                        Text(UserCache.shared.displayName(for: userId))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.textSecondary.opacity(0.7))
                    }

                    // At Store Button
                    Button(action: {
                    guard !viewModel.isSomeoneElseShopping else { return }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        showStoreSelection = true
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isSomeoneElseShopping ? "cart.fill.badge.questionmark" : "cart.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(viewModel.isSomeoneElseShopping ? "Shopping Active" : "At Store")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(viewModel.isSomeoneElseShopping ? .white.opacity(0.5) : .white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(viewModel.isSomeoneElseShopping
                                  ? Color.white.opacity(0.05)
                                  : DesignSystem.Colors.neonCyan.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(
                                        LinearGradient(
                                            colors: viewModel.isSomeoneElseShopping
                                                ? [Color.white.opacity(0.2)]
                                                : [DesignSystem.Colors.neonCyan, DesignSystem.Colors.neonCyan.opacity(0.3)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.5
                                    )
                            )
                            .shadow(color: viewModel.isSomeoneElseShopping
                                    ? .clear
                                    : DesignSystem.Shadows.neonCyanGlow,
                                    radius: 8, x: 0, y: 4)
                    )
                }
                .disabled(viewModel.isSomeoneElseShopping)
                }
            }

            // Compact shopping status line
            if viewModel.isSomeoneElseShopping {
                shoppingStatusLine
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 60)
        .padding(.bottom, 8)
    }

    // MARK: - Compact Shopping Status Line

    private var shoppingStatusLine: some View {
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
        .padding(.top, 4)
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
            // Item count - shown when no toast
            Text(viewModel.shoppingList.isEmpty ? "No items" : "\(viewModel.shoppingList.count) items")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
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
        DesignSystem.Colors.neonYellow.opacity(0.03)
    }

    // MARK: - Sort Options Bar

    private var sortOptionsBar: some View {
        HStack(spacing: 8) {
            ForEach(SortOption.allCases, id: \.self) { option in
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
                                  ? DesignSystem.Colors.neonCyan.opacity(0.3)
                                  : Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(viewModel.currentSort == option
                                    ? DesignSystem.Colors.neonCyan.opacity(0.5)
                                    : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            // Double-tap to scroll to top zone
            scrollToTopZone
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    // MARK: - Scroll to Top Zone

    private var scrollToTopZone: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color.white.opacity(0.03))
            .overlay(
                // Subtle chevron pattern
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Image(systemName: "chevron.up")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.15))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                scrollToTop()
            }
    }

    private func scrollToTop() {
        withAnimation(.easeOut(duration: 0.3)) {
            scrollProxy?.scrollTo("listTop", anchor: .top)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                .foregroundColor(DesignSystem.Colors.neonCyan)

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
                        .stroke(DesignSystem.Colors.neonCyan.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

#Preview {
    ShoppingListView()
        .environmentObject(ShoppingListViewModel())
        .environmentObject(AmplifyService.shared)
}
