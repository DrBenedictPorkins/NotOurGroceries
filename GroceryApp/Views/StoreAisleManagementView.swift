import SwiftUI
import UIKit

/// Main aisle management screen for viewing and editing product-aisle mappings
struct StoreAisleManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: ShoppingListViewModel
    @StateObject private var storeService = StoreService.shared
    @StateObject private var productCache = ProductCache.shared

    /// The store's id, not the store.
    ///
    /// This screen is pushed from a NavigationLink whose destination is rebuilt
    /// every time `householdStores` changes — and adding, deleting or reordering
    /// an aisle changes it. Holding the whole `HouseholdStore` made the
    /// destination a different value on every save, so SwiftUI threw this screen
    /// away and you landed back on Store Details mid-edit. An id does not change
    /// when the layout does.
    let storeId: String

    // MARK: - State
    @State private var isCleaning = false
    @State private var showAddAisle = false
    @State private var newAisleText = ""
    @State private var isAddingAisle = false
    /// The aisle being renamed, and the text of the correction.
    @State private var renamingAisle: OrderableAisle?
    @State private var renameText = ""
    /// The unmapped bucket is collapsed by default. On a new store it holds the
    /// entire product history — everything ever bought anywhere — which read as a
    /// backlog to work through. It is not: items get mapped when a list meets a
    /// store, and most of the catalogue is never bought at any given shop.

    // MARK: - Orderable Aisle for drag-to-reorder

    struct OrderableAisle: Identifiable {
        let id: String
        let displayName: String
        let displayOrder: Int
    }

    // MARK: - Computed Properties

    /// Get fresh store data from viewModel (updated after extraction completes)
    private var currentStore: HouseholdStore {
        viewModel.householdStores.first { $0.id == storeId }
            ?? HouseholdStore(id: storeId, householdId: "", name: "", chain: nil, address: nil, aisleLayout: [])
    }

    private var orderableAisles: [OrderableAisle] {
        var aisles: [OrderableAisle] = []

        // Add "Unknown" aisle if there are unmapped items
        let hasUnmappedItems = allDisplayItems.contains { $0.isUnmapped }
        if hasUnmappedItems {
            // Named for what it is — a bucket of items with no aisle yet — not
            // for an aisle whose name we cannot recall.
            aisles.append(OrderableAisle(id: "Unknown", displayName: "Not mapped to an aisle", displayOrder: 0))
        }

        // Add all aisles from currentStore.aisleLayout sorted by displayOrder
        let storeAisles = currentStore.aisleLayout.sorted { $0.displayOrder < $1.displayOrder }
        for aisle in storeAisles {
            let displayName = aisleDisplayName(aisle)
            aisles.append(OrderableAisle(id: aisle.id, displayName: displayName, displayOrder: aisle.displayOrder))
        }

        return aisles
    }

    private var mappings: [ProductAisleMapping] {
        storeService.productMappings[storeId] ?? []
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
                groceryItem: nil
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
                    groceryItem: item
                ))
            }
        }

        return items
    }

    /// Grouped by what the aisle is called, not by the id it is stored under.
    ///
    /// One shop accumulates several ids meaning the same place — a plain
    /// "Produce" from one write path and "standard-produce" from another — and
    /// grouping on the id listed that aisle twice, splitting its items between
    /// two identical headers.
    private var itemsGroupedByAisle: [String: [DisplayItem]] {
        Dictionary(grouping: allDisplayItems) { item in
            item.aisle == "Unknown"
                ? "Unknown"
                : AisleNaming.displayName(for: item.aisle, in: currentStore.aisleLayout)
        }
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
                .swipeActions(edge: .leading) {
                    if aisle.id != "Unknown" {
                        Button {
                            renameText = aisle.displayName
                            renamingAisle = aisle
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(DesignSystem.Colors.dillGreen)
                    }
                }
            }
            .onMove(perform: moveAisles)
            .onDelete(perform: deleteAisles)

            // Adding one lives here, next to the list of them. The usual way an
            // aisle appears is being named on an item while shopping; this is for
            // the times you already know.
            Button {
                newAisleText = ""
                showAddAisle = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.dillGreen)

                    Text("Add an aisle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.dillGreen)

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(DesignSystem.Colors.dillGreen.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DesignSystem.Colors.dillGreen.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        } header: {
            Text("AISLE ORDER")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DesignSystem.Colors.dillGreen)
                .tracking(1.0)
                .textCase(nil)
                .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 6, trailing: 20))
        } footer: {
            Text("Drag to reorder the walk · swipe to remove one")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
        }
        .listSectionSeparator(.hidden)
    }

    /// Add one aisle, by whatever the shop calls it.
    ///
    /// A number, a letter-number, or a name — the same values the aisle field on
    /// an item accepts, and stored the same way, so the two paths cannot disagree
    /// about what an aisle is.
    private func addAisle() {
        let trimmed = newAisleText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isAddingAisle else { return }

        // Already there under some spelling — adding it again would put the same
        // place in the walk twice.
        if AisleNaming.match(trimmed, in: currentStore.aisleLayout) != nil {
            viewModel.toastMessage = "\(trimmed) is already an aisle here"
            viewModel.toastType = .error
            viewModel.showToast = true
            return
        }

        isAddingAisle = true
        Task {
            do {
                let updated = try await storeService.addAisle(to: currentStore, number: trimmed, name: "")
                await MainActor.run {
                    if let index = viewModel.householdStores.firstIndex(where: { $0.id == updated.id }) {
                        viewModel.householdStores[index] = updated
                    }
                    viewModel.toastMessage = "Added \(trimmed)"
                    viewModel.toastType = .success
                    viewModel.showToast = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    // Said out loud rather than swallowed — a silent failure here
                    // looks identical to the aisle simply not appearing.
                    viewModel.toastMessage = "Could not add that aisle"
                    viewModel.toastType = .error
                    viewModel.showToast = true
                }
            }
            await MainActor.run { isAddingAisle = false }
        }
    }

    /// Correct an aisle's label. The aisle keeps its identity, so nothing that
    /// points at it has to be repaired.
    private func renameAisle() {
        guard let aisle = renamingAisle else { return }
        renamingAisle = nil

        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != aisle.displayName else { return }

        // Two aisles with the same label make voice capture ambiguous —
        // `AisleNaming.match` matches on name and number, and would have to pick
        // one of them.
        if let clash = AisleNaming.match(trimmed, in: currentStore.aisleLayout), clash.id != aisle.id {
            viewModel.toastMessage = "\(trimmed) is already an aisle here"
            viewModel.toastType = .error
            viewModel.showToast = true
            return
        }

        Task {
            do {
                let updated = try await storeService.renameAisle(in: currentStore, aisleId: aisle.id, to: trimmed)
                await MainActor.run {
                    applyStoreUpdate(updated)
                    viewModel.toastMessage = "Renamed to \(trimmed)"
                    viewModel.toastType = .success
                    viewModel.showToast = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    viewModel.toastMessage = "Couldn't rename that aisle"
                    viewModel.toastType = .error
                    viewModel.showToast = true
                }
            }
        }
    }

    private func moveAisles(from source: IndexSet, to destination: Int) {
        var aisleIds = orderableAisles.map { $0.id }
        aisleIds.move(fromOffsets: source, toOffset: destination)

        // "Unknown" is a bucket for unmapped items, not a row in the layout.
        let realAisleIds = aisleIds.filter { $0 != "Unknown" }

        Task {
            do {
                // `currentStore`, not the `store` prop — the prop is whatever was
                // passed in when this screen opened and can be several scans out
                // of date.
                let updated = try await storeService.reorderAisles(in: currentStore, newOrder: realAisleIds)
                // The result used to be discarded, so the view model kept the old
                // order, the list re-rendered from it, and the drag snapped back.
                // It looked as though reordering did not work; it worked and was
                // then thrown away.
                applyStoreUpdate(updated)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } catch {
                await MainActor.run {
                    viewModel.toastMessage = "Couldn't save the new order: \(error.localizedDescription)"
                    viewModel.toastType = .error
                    viewModel.showToast = true
                }
            }
        }
    }

    /// Put a freshly saved store back where every view reads it from.
    private func applyStoreUpdate(_ updated: HouseholdStore) {
        if let index = viewModel.householdStores.firstIndex(where: { $0.id == updated.id }) {
            viewModel.householdStores[index] = updated
        }
    }

    private func deleteAisles(at offsets: IndexSet) {
        let doomed = offsets
            .map { orderableAisles[$0] }
            .filter { $0.id != "Unknown" }

        Task {
            for aisle in doomed {
                do {
                    let updated = try await storeService.removeAisle(from: currentStore, aisleId: aisle.id)
                    applyStoreUpdate(updated)
                    // Items mapped to it would otherwise point at an aisle that
                    // no longer exists, which reads as a section header made of
                    // a raw id and blocks inference from ever re-assigning them.
                    try? await storeService.pruneOrphanedMappings(storeId: currentStore.id)
                    viewModel.toastMessage = "Removed \(aisle.displayName)"
                    viewModel.toastType = .success
                    viewModel.showToast = true
                } catch {
                    viewModel.toastMessage = "Couldn't remove \(aisle.displayName): \(error.localizedDescription)"
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

                // This screen is the store's layout: which aisles it has and the
                // order you walk them. It is not about what is on your list.
                // Products, their mappings, confidence scores and the "bought
                // elsewhere" backlog all used to live here, which made a screen
                // titled Aisle Setup read as a review queue.
                List {
                    aisleOrderSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Aisle Management")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename aisle", isPresented: Binding(
            get: { renamingAisle != nil },
            set: { if !$0 { renamingAisle = nil } }
        )) {
            TextField("Number or name — 7, A2, Bakery", text: $renameText)
            Button("Cancel", role: .cancel) { renamingAisle = nil }
            Button("Save") { renameAisle() }
        } message: {
            Text("Items already in this aisle stay in it.")
        }
        .alert("Add an aisle", isPresented: $showAddAisle) {
            TextField("Number or name — 7, A2, Bakery", text: $newAisleText)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { }
            Button("Add") { addAisle() }
        } message: {
            Text("Aisles you add sit at the end of the walk. Drag it into place afterwards.")
        }
        .task {
            // Load mappings if not already loaded
            if mappings.isEmpty {
                try? await storeService.fetchMappings(storeId: storeId)
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        // Done sits here rather than in a navigation bar because this sheet has
        // no navigation bar. Without it the only way out was a downward swipe,
        // which is not something a screen full of drag handles invites you to
        // try — the rows want to be dragged, so dragging the sheet is the last
        // thing you would attempt.
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AISLE SETUP")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(DesignSystem.Colors.textTertiary)

                Text(currentStore.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.accentGradient)

                if let chain = currentStore.chain, !chain.isEmpty {
                    Text(chain)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }

            Spacer(minLength: 12)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DesignSystem.Colors.dillGreen)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.dillGreen.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(DesignSystem.Colors.dillGreen.opacity(0.35), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Action Buttons







    // MARK: - Section Header


    /// The fifth copy of this in the codebase, and the one that produced "Aisle
    /// Dairy" — it prefixed "Aisle" onto any number, including one that is a word.
    private func aisleDisplayName(_ aisle: StoreAisle) -> String {
        AisleNaming.displayName(for: aisle.id, in: [aisle])
    }

    // MARK: - Actions


    private func cleanupInvalidMappings() async {
        isCleaning = true
        defer { isCleaning = false }

        do {
            let deletedCount = try await storeService.cleanupInvalidMappings(storeId: storeId)
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






// MARK: - Aisle Selection Row


// MARK: - Preview

#Preview {
    StoreAisleManagementView(storeId: HouseholdStore.preview.id)
        .environmentObject(ShoppingListViewModel())
}
