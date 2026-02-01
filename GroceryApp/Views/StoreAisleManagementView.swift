import SwiftUI
import UIKit

/// Main aisle management screen for viewing and editing product-aisle mappings
struct StoreAisleManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared
    @StateObject private var productCache = ProductCache.shared

    let store: HouseholdStore

    // MARK: - State
    @State private var showAisleScanSheet = false
    @State private var isCleaning = false
    @State private var selectedMapping: ProductAisleMapping? = nil
    @State private var showEditSheet = false
    @State private var searchText = ""

    // MARK: - Orderable Aisle for drag-to-reorder

    struct OrderableAisle: Identifiable {
        let id: String
        let displayName: String
        let displayOrder: Int
    }

    // MARK: - Computed Properties

    private var orderableAisles: [OrderableAisle] {
        var aisles: [OrderableAisle] = []

        // Add "Unknown" aisle if there are unmapped items
        let hasUnmappedItems = allDisplayItems.contains { $0.isUnmapped }
        if hasUnmappedItems {
            aisles.append(OrderableAisle(id: "Unknown", displayName: "Unknown Aisle", displayOrder: 0))
        }

        // Add all aisles from store.aisleLayout sorted by displayOrder
        let storeAisles = store.aisleLayout.sorted { $0.displayOrder < $1.displayOrder }
        for aisle in storeAisles {
            let displayName = aisleDisplayName(aisle)
            aisles.append(OrderableAisle(id: aisle.id, displayName: displayName, displayOrder: aisle.displayOrder))
        }

        return aisles
    }

    private var mappings: [ProductAisleMapping] {
        storeService.productMappings[store.id] ?? []
    }

    /// All grocery items in the household
    private var allGroceryItems: [GroceryItem] {
        viewModel.items
    }

    /// Unified display item - can represent a mapping or an unmapped grocery item
    struct DisplayItem: Identifiable {
        let id: String
        let name: String
        let aisle: String
        let mapping: ProductAisleMapping?
        let groceryItem: GroceryItem?
        let quantity: String?

        var isUnmapped: Bool { mapping == nil }
    }

    /// Build display items from all community mappings + unmapped grocery items
    private var allDisplayItems: [DisplayItem] {
        var items: [DisplayItem] = []
        var mappedProductIds = Set<String>()
        var mappedNormalizedNames = Set<String>()  // Store lowercase for case-insensitive comparison

        // First, add all community product mappings
        for mapping in mappings {
            let name = mapping.normalizedName?.capitalized
                ?? productCache.product(byId: mapping.productId ?? "")?.name
                ?? mapping.productId ?? "Unknown"

            items.append(DisplayItem(
                id: mapping.id,
                name: name,
                aisle: mapping.effectiveAisle,
                mapping: mapping,
                groceryItem: nil,
                quantity: nil
            ))

            // Track what's been mapped (lowercase for case-insensitive comparison)
            if let productId = mapping.productId {
                mappedProductIds.insert(productId)
            }
            if let normalizedName = mapping.normalizedName {
                mappedNormalizedNames.insert(normalizedName.lowercased())
            }
        }

        // Then, add grocery items that DON'T have mappings (case-insensitive check)
        for item in allGroceryItems {
            let hasMappingByProductId = item.productId.map { mappedProductIds.contains($0) } ?? false
            let hasMappingByName = mappedNormalizedNames.contains(item.normalizedName.lowercased())

            if !hasMappingByProductId && !hasMappingByName {
                items.append(DisplayItem(
                    id: "grocery-\(item.id)",
                    name: item.name,
                    aisle: "Unknown",
                    mapping: nil,
                    groceryItem: item,
                    quantity: item.quantity
                ))
            }
        }

        return items
    }

    private var filteredDisplayItems: [DisplayItem] {
        if searchText.isEmpty {
            return allDisplayItems
        }
        return allDisplayItems.filter { item in
            item.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var itemsGroupedByAisle: [String: [DisplayItem]] {
        Dictionary(grouping: filteredDisplayItems) { $0.aisle }
    }

    private var sortedAisleKeys: [String] {
        // Sort aisles: numeric first (by number), then alphabetic, "Unknown" last
        itemsGroupedByAisle.keys.sorted { key1, key2 in
            // Unknown always goes last
            if key1 == "Unknown" { return false }
            if key2 == "Unknown" { return true }

            let num1 = Int(key1)
            let num2 = Int(key2)
            // Both numeric - sort by number
            if let n1 = num1, let n2 = num2 {
                return n1 < n2
            }
            // Only first is numeric - it comes first
            if num1 != nil { return true }
            // Only second is numeric - it comes first
            if num2 != nil { return false }
            // Both non-numeric - sort alphabetically
            return key1 < key2
        }
    }

    // Stats
    private var totalItems: Int { allDisplayItems.count }
    private var mappedCount: Int { mappings.count }
    private var unmappedCount: Int { allDisplayItems.filter { $0.isUnmapped }.count }
    private var lowConfidenceCount: Int {
        mappings.filter { ($0.confidence ?? 1.0) < 0.7 }.count
    }

    /// Count of mappings with UUID-like aisleIds (invalid)
    private var invalidMappingsCount: Int {
        let uuidPattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        guard let regex = try? NSRegularExpression(pattern: uuidPattern) else { return 0 }
        return mappings.filter { mapping in
            let range = NSRange(mapping.aisleId.startIndex..., in: mapping.aisleId)
            return regex.firstMatch(in: mapping.aisleId, range: range) != nil
        }.count
    }

    // MARK: - Aisle Order Section

    private var aisleOrderSection: some View {
        Section {
            ForEach(orderableAisles) { aisle in
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)

                    Text(aisle.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.glassBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                        )
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            }
            .onMove(perform: moveAisles)
        } header: {
            Text("AISLE ORDER")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DesignSystem.Colors.neonCyan)
                .tracking(1.0)
                .textCase(nil)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 6, trailing: 20))
        } footer: {
            Text("Drag to reorder shopping sequence")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
        }
        .listSectionSeparator(.hidden)
    }

    private func moveAisles(from source: IndexSet, to destination: Int) {
        var aisleIds = orderableAisles.map { $0.id }
        aisleIds.move(fromOffsets: source, toOffset: destination)

        // Filter out "Unknown" since it's not a real aisle in the store layout
        let realAisleIds = aisleIds.filter { $0 != "Unknown" }

        Task {
            do {
                _ = try await storeService.reorderAisles(in: store, newOrder: realAisleIds)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } catch {
                await MainActor.run {
                    viewModel.toastMessage = "Failed to reorder aisles: \(error.localizedDescription)"
                    viewModel.toastType = .error
                    viewModel.showToast = true
                }
            }
        }
    }

    var body: some View {
        ZStack {
            // Background
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.darkMetallicGradient
                .ignoresSafeArea()
                .opacity(0.3)

            VStack(spacing: 0) {
                // Header with store name
                headerView

                // Action buttons
                actionButtonsView

                // Search bar
                searchBarView

                // Items list (grouped by aisle)
                if allGroceryItems.isEmpty {
                    emptyStateView
                } else {
                    itemsListView
                }

                // Stats footer
                statsFooterView
            }
        }
        .navigationTitle("Aisle Management")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAisleScanSheet) {
            AisleScanSheet(store: store) {
                // Refresh mappings after processing complete
                Task {
                    try? await storeService.fetchMappings(storeId: store.id)
                }
            }
            .environmentObject(viewModel)
        }
        .sheet(isPresented: $showEditSheet) {
            if let mapping = selectedMapping {
                MappingEditSheet(mapping: mapping, store: store)
                    .environmentObject(viewModel)
            }
        }
        .task {
            // Load mappings if not already loaded
            if mappings.isEmpty {
                try? await storeService.fetchMappings(storeId: store.id)
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.accentGradient)

            if let chain = store.chain, !chain.isEmpty {
                Text(chain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Action Buttons

    private var actionButtonsView: some View {
        HStack(spacing: 12) {
            // Scan Directory Button
            Button(action: {
                showAisleScanSheet = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Scan Directory")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.neonCyan.opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DesignSystem.Colors.neonCyan, lineWidth: 1)
                        )
                )
            }

            // Cleanup Invalid Button (only show if there are invalid mappings)
            if invalidMappingsCount > 0 {
                Button(action: {
                    Task {
                        await cleanupInvalidMappings()
                    }
                }) {
                    HStack(spacing: 8) {
                        if isCleaning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text("Clean (\(invalidMappingsCount))")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(DesignSystem.Colors.error.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(DesignSystem.Colors.error, lineWidth: 1)
                            )
                    )
                }
                .disabled(isCleaning)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Search Bar

    private var searchBarView: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)

            TextField("Search products...", text: $searchText)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.white)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystem.Colors.glassBorder, lineWidth: 1)
                )
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Items List

    private var itemsListView: some View {
        List {
            // Aisle order section at the top
            aisleOrderSection

            // Product items grouped by aisle
            ForEach(sortedAisleKeys, id: \.self) { aisleId in
                Section {
                    if let aisleItems = itemsGroupedByAisle[aisleId] {
                        ForEach(aisleItems) { displayItem in
                            DisplayItemRow(displayItem: displayItem)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                                .onTapGesture {
                                    if let mapping = displayItem.mapping {
                                        selectedMapping = mapping
                                        showEditSheet = true
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                }
                        }
                    }
                } header: {
                    aisleSectionHeader(for: aisleId)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "cart")
                .font(.system(size: 48, weight: .thin))
                .foregroundColor(.white.opacity(0.3))

            Text("No Items in List")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            Text("Add items to your shopping list, then scan a store directory to map them to aisles")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Stats Footer

    private var statsFooterView: some View {
        HStack(spacing: 16) {
            StatBadge(count: mappedCount, label: "mapped", color: DesignSystem.Colors.neonCyan)
            StatBadge(count: unmappedCount, label: "unmapped", color: DesignSystem.Colors.neonPink)
            StatBadge(count: lowConfidenceCount, label: "low conf.", color: DesignSystem.Colors.warning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            Rectangle()
                .fill(DesignSystem.Colors.background.opacity(0.95))
                .shadow(color: .black.opacity(0.2), radius: 8, y: -4)
        )
    }

    // MARK: - Section Header

    private func aisleSectionHeader(for aisleId: String) -> some View {
        let displayName: String
        let headerColor: Color

        if aisleId == "Unknown" {
            displayName = "Unknown Aisle"
            headerColor = DesignSystem.Colors.neonPink
        } else if let aisle = store.aisleLayout.first(where: { $0.id == aisleId }) {
            // Use store's custom aisle name if defined
            displayName = aisleDisplayName(aisle)
            headerColor = DesignSystem.Colors.neonCyan
        } else if let aisleNum = Int(aisleId) {
            // Numeric aisle - format as "Aisle X"
            displayName = "Aisle \(aisleNum)"
            headerColor = DesignSystem.Colors.neonCyan
        } else {
            // Named aisle (Dairy, Meat, Deli, etc.) - use as-is
            displayName = aisleId
            headerColor = DesignSystem.Colors.neonCyan
        }
        let count = itemsGroupedByAisle[aisleId]?.count ?? 0

        return HStack(spacing: 8) {
            Image(systemName: aisleId == "Unknown" ? "questionmark.circle" : "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(headerColor)

            Text(displayName.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(headerColor)
                .tracking(1.0)

            Spacer()

            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 6, trailing: 20))
    }

    private func aisleDisplayName(_ aisle: StoreAisle) -> String {
        if aisle.number.isEmpty && aisle.name.isEmpty {
            return "Unknown"
        }
        if aisle.number.isEmpty {
            return aisle.name
        }
        if aisle.name.isEmpty || aisle.number.lowercased() == aisle.name.lowercased() {
            return "Aisle \(aisle.number)"
        }
        return "Aisle \(aisle.number) - \(aisle.name)"
    }

    // MARK: - Actions

    private func processExtractedAisles(_ aisles: [ExtractedAisle]) async {
        // Lambda already saved mappings to DynamoDB - just refresh the local cache
        do {
            try await storeService.fetchMappings(storeId: store.id)
            await MainActor.run {
                let productCount = aisles.reduce(0) { $0 + $1.products.count }
                viewModel.toastMessage = "Extracted \(productCount) products from \(aisles.count) aisles"
                viewModel.toastType = .success
                viewModel.showToast = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            await MainActor.run {
                viewModel.toastMessage = "Failed to refresh mappings: \(error.localizedDescription)"
                viewModel.toastType = .error
                viewModel.showToast = true
            }
        }
    }

    private func cleanupInvalidMappings() async {
        isCleaning = true
        defer { isCleaning = false }

        do {
            let deletedCount = try await storeService.cleanupInvalidMappings(storeId: store.id)
            await MainActor.run {
                viewModel.toastMessage = "Cleaned up \(deletedCount) invalid mappings"
                viewModel.toastType = .success
                viewModel.showToast = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } catch {
            await MainActor.run {
                viewModel.toastMessage = "Cleanup failed: \(error.localizedDescription)"
                viewModel.toastType = .error
                viewModel.showToast = true
            }
        }
    }
}

// MARK: - Display Item Row (unified row for mappings and unmapped items)

private struct DisplayItemRow: View {
    let displayItem: StoreAisleManagementView.DisplayItem

    private var confidencePercent: Int {
        Int((displayItem.mapping?.confidence ?? 0) * 100)
    }

    private var isLowConfidence: Bool {
        guard let conf = displayItem.mapping?.confidence else { return false }
        return conf < 0.7
    }

    private var hasUserOverride: Bool {
        displayItem.mapping?.userAisleOverride != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // Item name and details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayItem.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(displayItem.isUnmapped ? .white.opacity(0.7) : .white)

                    if let quantity = displayItem.quantity, !quantity.isEmpty {
                        Text(quantity)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DesignSystem.Colors.neonCyan.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.neonCyan.opacity(0.15))
                            )
                    }
                }

                if let reasoning = displayItem.mapping?.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Status indicators
            HStack(spacing: 8) {
                if displayItem.isUnmapped {
                    // Unmapped indicator
                    Text("No mapping")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.neonPink.opacity(0.8))
                } else {
                    // User override indicator
                    if hasUserOverride {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                            Text("(you)")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(DesignSystem.Colors.success)
                    }

                    // Low confidence warning
                    if isLowConfidence && !hasUserOverride {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(DesignSystem.Colors.warning)
                    }

                    // Confidence percentage
                    if !hasUserOverride {
                        Text("\(confidencePercent)%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isLowConfidence ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary)
                    }

                    // Chevron (only for mapped items that can be edited)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            displayItem.isUnmapped
                                ? DesignSystem.Colors.neonPink.opacity(0.3)
                                : (isLowConfidence && !hasUserOverride
                                    ? DesignSystem.Colors.warning.opacity(0.3)
                                    : DesignSystem.Colors.glassBorder),
                            lineWidth: 1
                        )
                )
        )
    }
}

// MARK: - Mapping Row (legacy - kept for edit sheet)

private struct MappingRow: View {
    let mapping: ProductAisleMapping
    let store: HouseholdStore
    let productCache: ProductCache

    private var productName: String {
        // First try normalizedName
        if let name = mapping.normalizedName, !name.isEmpty {
            return name.capitalized
        }
        // Then try looking up by productId in cache
        if let productId = mapping.productId,
           let product = productCache.product(byId: productId) {
            return product.name
        }
        // Last resort - show truncated ID
        if let productId = mapping.productId {
            return String(productId.prefix(8)) + "..."
        }
        return "Unknown Product"
    }

    private var aisleName: String {
        if let aisle = store.aisleLayout.first(where: { $0.id == mapping.effectiveAisle }) {
            return aisle.number.isEmpty ? aisle.name : "Aisle \(aisle.number)"
        }
        return mapping.effectiveAisle
    }

    private var confidencePercent: Int {
        Int((mapping.confidence ?? 1.0) * 100)
    }

    private var isLowConfidence: Bool {
        (mapping.confidence ?? 1.0) < 0.7
    }

    private var hasUserOverride: Bool {
        mapping.userAisleOverride != nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // Product name
            VStack(alignment: .leading, spacing: 4) {
                Text(productName.capitalized)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)

                if let reasoning = mapping.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Status indicators
            HStack(spacing: 8) {
                // User override indicator
                if hasUserOverride {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                        Text("(you set)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(DesignSystem.Colors.success)
                }

                // Low confidence warning
                if isLowConfidence && !hasUserOverride {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(DesignSystem.Colors.warning)
                }

                // Confidence percentage
                if !hasUserOverride {
                    Text("\(confidencePercent)%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isLowConfidence ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary)
                }

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystem.Colors.glassBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isLowConfidence && !hasUserOverride
                                ? DesignSystem.Colors.warning.opacity(0.3)
                                : DesignSystem.Colors.glassBorder,
                            lineWidth: 1
                        )
                )
        )
    }
}

// MARK: - Stat Badge

private struct StatBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(color)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Mapping Edit Sheet

private struct MappingEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared

    let mapping: ProductAisleMapping
    let store: HouseholdStore

    @State private var selectedAisleId: String
    @State private var isSaving = false
    @State private var customAisle: String = ""
    @State private var showCustomInput = false

    init(mapping: ProductAisleMapping, store: HouseholdStore) {
        self.mapping = mapping
        self.store = store
        _selectedAisleId = State(initialValue: mapping.effectiveAisle)
    }

    private var productName: String {
        mapping.normalizedName ?? mapping.productId ?? "Unknown Product"
    }

    /// Get available aisles from existing mappings (not from store.aisleLayout which may be empty)
    private var availableAisles: [String] {
        let mappings = storeService.productMappings[store.id] ?? []
        let aisleIds = Set(mappings.map { $0.effectiveAisle })
        // Sort: numeric first, then alphabetic
        return aisleIds.sorted { a, b in
            let aNum = Int(a)
            let bNum = Int(b)
            if let aInt = aNum, let bInt = bNum { return aInt < bInt }
            if aNum != nil { return true }
            if bNum != nil { return false }
            return a < b
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                DesignSystem.Colors.background
                    .ignoresSafeArea()

                DesignSystem.Colors.darkMetallicGradient
                    .ignoresSafeArea()
                    .opacity(0.3)

                VStack(spacing: 24) {
                    // Product info
                    VStack(spacing: 8) {
                        Text(productName.capitalized)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)

                        if let reasoning = mapping.reasoning {
                            Text("LLM reasoning: \(reasoning)")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }

                        if mapping.userAisleOverride == nil {
                            Text("Confidence: \(Int((mapping.confidence ?? 1.0) * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(
                                    (mapping.confidence ?? 1.0) < 0.7
                                        ? DesignSystem.Colors.warning
                                        : DesignSystem.Colors.success
                                )
                        }

                        if mapping.userAisleOverride != nil {
                            Button(action: clearOverride) {
                                Text("Reset to LLM suggestion (\(mapping.aisleId))")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(DesignSystem.Colors.neonCyan)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.top, 24)

                    // Aisle selection
                    Text("Select Aisle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)

                    ScrollView {
                        VStack(spacing: 8) {
                            // Show aisles from existing mappings
                            ForEach(availableAisles, id: \.self) { aisleId in
                                AisleSelectionRowSimple(
                                    aisleId: aisleId,
                                    isSelected: aisleId == selectedAisleId
                                ) {
                                    selectedAisleId = aisleId
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }

                            // Custom aisle input
                            if showCustomInput {
                                HStack(spacing: 12) {
                                    TextField("Enter aisle...", text: $customAisle)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white)
                                        .padding(16)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(DesignSystem.Colors.glassBackground)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .stroke(DesignSystem.Colors.neonCyan, lineWidth: 1.5)
                                                )
                                        )

                                    Button(action: {
                                        if !customAisle.isEmpty {
                                            selectedAisleId = customAisle
                                            showCustomInput = false
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        }
                                    }) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 24))
                                            .foregroundColor(DesignSystem.Colors.neonCyan)
                                    }
                                }
                            } else {
                                Button(action: {
                                    showCustomInput = true
                                }) {
                                    HStack {
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 16))
                                        Text("Add Custom Aisle")
                                            .font(.system(size: 15, weight: .medium))
                                    }
                                    .foregroundColor(DesignSystem.Colors.neonCyan)
                                    .frame(maxWidth: .infinity)
                                    .padding(16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(
                                                style: StrokeStyle(lineWidth: 1, dash: [6, 3])
                                            )
                                            .foregroundColor(DesignSystem.Colors.neonCyan.opacity(0.5))
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }

                    Spacer()

                    // Save button
                    Button(action: saveOverride) {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text(isSaving ? "Saving..." : "Save Override")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(DesignSystem.Colors.accentGradient)
                        )
                    }
                    .disabled(isSaving || selectedAisleId == mapping.effectiveAisle)
                    .opacity(selectedAisleId == mapping.effectiveAisle ? 0.5 : 1.0)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Edit Mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(DesignSystem.Colors.neonCyan)
                    .disabled(isSaving)
                }
            }
        }
    }

    private func saveOverride() {
        guard selectedAisleId != mapping.effectiveAisle else { return }

        isSaving = true
        Task {
            do {
                try await AisleExtractionService.shared.updateUserOverride(
                    mappingId: mapping.id,
                    userAisleOverride: selectedAisleId
                )
                // Refresh mappings to get updated data
                try await storeService.fetchMappings(storeId: store.id)

                await MainActor.run {
                    isSaving = false
                    dismiss()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    // Show error via toast on parent view
                    viewModel.toastMessage = "Failed to save: \(error.localizedDescription)"
                    viewModel.toastType = .error
                    viewModel.showToast = true
                }
            }
        }
    }

    private func clearOverride() {
        isSaving = true
        Task {
            do {
                try await AisleExtractionService.shared.updateUserOverride(
                    mappingId: mapping.id,
                    userAisleOverride: nil
                )
                try await storeService.fetchMappings(storeId: store.id)

                await MainActor.run {
                    isSaving = false
                    dismiss()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    viewModel.toastMessage = "Failed to reset: \(error.localizedDescription)"
                    viewModel.toastType = .error
                    viewModel.showToast = true
                }
            }
        }
    }
}

// MARK: - Aisle Selection Row (Simple - uses string ID)

private struct AisleSelectionRowSimple: View {
    let aisleId: String
    let isSelected: Bool
    let action: () -> Void

    private var displayName: String {
        if let num = Int(aisleId) {
            return "Aisle \(num)"
        }
        return aisleId
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(DesignSystem.Colors.neonCyan)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected
                        ? DesignSystem.Colors.neonCyan.opacity(0.1)
                        : DesignSystem.Colors.glassBackground
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected
                                    ? DesignSystem.Colors.neonCyan
                                    : DesignSystem.Colors.glassBorder,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Aisle Selection Row

private struct AisleSelectionRow: View {
    let aisle: StoreAisle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(aisle.number.isEmpty ? aisle.name : "Aisle \(aisle.number)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)

                    if !aisle.number.isEmpty && !aisle.name.isEmpty && aisle.number != aisle.name {
                        Text(aisle.name)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(DesignSystem.Colors.neonCyan)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected
                        ? DesignSystem.Colors.neonCyan.opacity(0.1)
                        : DesignSystem.Colors.glassBackground
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isSelected
                                    ? DesignSystem.Colors.neonCyan
                                    : DesignSystem.Colors.glassBorder,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    StoreAisleManagementView(store: HouseholdStore.preview)
        .environmentObject(ShoppingListViewModel())
}
