import SwiftUI
import Combine
import Amplify
import AudioToolbox
import os.log

private let logger = Logger(subsystem: "com.byteclub.grocery.app", category: "ShoppingList")

enum SortOption: String, CaseIterable {
    case recentFirst = "Recent"
    case aToZ = "A-Z"
    case zToA = "Z-A"

    var icon: String {
        switch self {
        case .recentFirst: return "clock"
        case .aToZ: return "arrow.down"
        case .zToA: return "arrow.up"
        }
    }
}

// MARK: - Shopping Status Enum
enum ShoppingStatus: String, Codable {
    case idle = "IDLE"
    case atStore = "AT_STORE"
}

@MainActor
class ShoppingListViewModel: ObservableObject {
    // MARK: - Published State
    @Published var items: [GroceryItem] = []
    @Published var isAtStoreMode: Bool = false
    @Published var selectedStore: Store?
    @Published var householdStores: [HouseholdStore] = []
    @Published var selectedHouseholdStore: HouseholdStore?
    @Published var productAisleMappings: [String: [ProductAisleMapping]] = [:] // storeId -> mappings
    @Published var showToast: Bool = false
    @Published var toastMessage: String = ""
    @Published var toastUserName: String = ""
    @Published var toastType: ToastType = .success
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var searchResults: [Product] = []
    @Published var currentSort: SortOption = .recentFirst

    // MARK: - Shopping Mode State
    @Published var shoppingStatus: ShoppingStatus = .idle
    @Published var activeShopperId: String?
    @Published var shoppingStoreId: String?
    @Published var shoppingStartedAt: Date?
    @Published var shoppingCompletionStats: ShoppingCompletionStats?
    @Published var showShoppingCompletedSheet = false

    // MARK: - Shopping Request Inbox
    @Published var pendingRequests: [ShoppingRequest] = []
    @Published var showInboxSheet = false

    // MARK: - Computed Properties for Filtered Views

    /// Items on the shopping list (active items to be picked up)
    var shoppingList: [GroceryItem] {
        items.filter { $0.status == .active }
    }

    /// Items already in the cart during the current shopping trip
    var inCart: [GroceryItem] {
        items.filter { $0.status == .inCart }
    }

    /// Suggested items from previous shopping trips
    var suggestions: [GroceryItem] {
        items.filter { $0.status == .suggestion }
    }

    /// Returns true if the current user is the active shopper
    var isCurrentUserShopping: Bool {
        // If we're locally in "At Store" mode, we're the shopper
        if isAtStoreMode {
            return true
        }
        // Otherwise check the household-level status from backend
        guard shoppingStatus == .atStore,
              let shopperId = activeShopperId,
              let currentUserId = AmplifyService.shared.currentUser?.userId else {
            return false
        }
        return shopperId == currentUserId
    }

    /// Returns true if someone else in the household is shopping
    var isSomeoneElseShopping: Bool {
        guard shoppingStatus == .atStore,
              let shopperId = activeShopperId,
              let currentUserId = AmplifyService.shared.currentUser?.userId else {
            return false
        }
        return shopperId != currentUserId
    }

    /// Get the display name of the active shopper
    var activeShopperDisplayName: String? {
        guard let shopperId = activeShopperId else { return nil }
        return UserCache.shared.displayName(for: shopperId)
    }

    /// Number of pending shopping requests
    var pendingRequestCount: Int {
        pendingRequests.count
    }

    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    private var subscriptionCancellables = Set<AnyCancellable>()
    private var householdChangedObserver: NSObjectProtocol?
    private var pendingOptimisticIds: Set<String> = []
    private var pendingRemovals: Set<String> = []
    private var hasLoadedInitialData = false
    private var reminderTimer: Timer?

    var householdId: String? {
        AmplifyService.shared.currentHouseholdId
    }

    // MARK: - Initialization
    init() {
        setupHouseholdChangeObserver()
    }

    deinit {
        if let observer = householdChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        reminderTimer?.invalidate()
    }

    private func setupHouseholdChangeObserver() {
        householdChangedObserver = NotificationCenter.default.addObserver(
            forName: .householdChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleHouseholdChanged()
            }
        }
    }

    private func handleHouseholdChanged() {
        // Clear local data
        items = []
        householdStores = []
        hasLoadedInitialData = false

        // Clear user cache for old household
        UserCache.shared.clear()

        // Teardown old subscriptions
        teardownSubscriptions()

        // If we have a new household, reload (which will also setup subscriptions)
        if householdId != nil {
            Task {
                await loadShoppingList(forceRefresh: true)
                await loadStores(forceRefresh: true)
            }
        }
    }

    // MARK: - Data Loading
    func loadShoppingList(forceRefresh: Bool = false) async {
        // Skip if already loaded (prevents jerky redraws on tab switch)
        if hasLoadedInitialData && !forceRefresh {
            return
        }

        // Wait for householdId to be loaded from UserDefaults
        var attempts = 0
        while householdId == nil && attempts < 10 {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            attempts += 1
        }

        guard let householdId = householdId else {
            logger.error("loadShoppingList: No household ID available")
            return
        }

        isLoading = true
        defer { isLoading = false; hasLoadedInitialData = true }

        do {
            // Fetch all items for the household using filter-based query
            // Note: listItemsByHouseholdAndStatus requires status param, so we use listGroceryItems with filter
            let document = """
            query ListGroceryItems($filter: ModelGroceryItemFilterInput, $limit: Int) {
                listGroceryItems(filter: $filter, limit: $limit) {
                    items {
                        id
                        householdId
                        name
                        normalizedName
                        quantity
                        notes
                        isCustom
                        productId
                        status
                        lockedBy
                        addedBy
                        addedAt
                        version
                        reactions
                        images
                    }
                }
            }
            """

            let filter: [String: Any] = [
                "householdId": ["eq": householdId]
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["filter": filter, "limit": 1000],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.query(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let listResult) = root["listGroceryItems"],
                   case .array(let itemsJson) = listResult["items"] {
                    self.items = itemsJson.compactMap { parseGroceryItem($0) }
                    applySorting()

                    logger.info("Loaded \(self.items.count) items: \(self.shoppingList.count) active, \(self.inCart.count) in cart, \(self.suggestions.count) suggestions")
                } else {
                    logger.error("Failed to parse items response structure")
                }
            case .failure(let error):
                logger.error("Failed to fetch items: \(String(describing: error))")
                self.errorMessage = error.localizedDescription
                if AmplifyService.shared.isAuthError(error) {
                    try? await AmplifyService.shared.signOut()
                    return
                }
            }

        } catch {
            logger.error("Error loading shopping list: \(error)")
            errorMessage = error.localizedDescription
            AmplifyService.shared.handleAuthError(error)
        }

        // Populate caches in parallel
        async let userCacheFetch: () = UserCache.shared.fetchUsersForHousehold(householdId)
        async let productCacheFetch: () = ProductCache.shared.fetchAllProducts()
        async let storesFetch: () = loadStores()
        _ = await (userCacheFetch, productCacheFetch, storesFetch)

        // Setup subscriptions for real-time sync
        setupSubscriptions()
    }

    @MainActor
    func refreshAllData() async {
        logger.info("Refreshing all data...")

        // Parallel fetch
        async let itemsTask: () = loadShoppingList(forceRefresh: true)
        async let storesTask: () = loadStores(forceRefresh: true)

        _ = await (itemsTask, storesTask)

        // Refresh mappings for current store
        if let storeId = shoppingStoreId ?? householdStores.first?.id {
            _ = try? await StoreService.shared.fetchMappings(storeId: storeId)
        }

        // Refresh household member cache
        if let householdId = householdId {
            await UserCache.shared.fetchUsersForHousehold(householdId)
        }

        logger.info("All data refreshed")
    }

    // MARK: - Name Normalization

    private func normalizeName(_ name: String) -> String {
        var result = name.lowercased().trimmingCharacters(in: .whitespaces)

        // Remove articles at the beginning
        let articles = ["a ", "an ", "the "]
        for article in articles {
            if result.hasPrefix(article) {
                result = String(result.dropFirst(article.count))
            }
        }

        // Handle plurals: remove trailing 's' if it exists
        if result.hasSuffix("s") && result.count > 1 {
            let singularCandidate = String(result.dropLast())
            // Avoid over-aggressive stripping (e.g., "grass" -> "gras")
            // Simple heuristic: if length > 3, allow plural removal
            if singularCandidate.count >= 3 {
                result = singularCandidate
            }
        }

        return result
    }

    // MARK: - Add Item
    func addItem(name: String, quantity: String? = nil, notes: String? = nil, productId: String? = nil) async {
        // If someone else is shopping, submit a request instead of adding directly
        if isSomeoneElseShopping {
            let normalizedName = normalizeName(name)
            await submitAddRequest(
                name: name,
                quantity: quantity,
                notes: notes,
                productId: productId,
                normalizedName: normalizedName
            )
            return
        }

        guard let householdId = householdId else {
            showToast(message: "No household selected")
            return
        }

        let currentUserId = AmplifyService.shared.currentUser?.userId ?? ""
        guard !currentUserId.isEmpty else {
            showToast(message: "Not signed in", type: .warning)
            return
        }

        // Check for duplicates in cached list
        let normalizedName = normalizeName(name)
        if let existingItem = shoppingList.first(where: { $0.normalizedName == normalizedName }) {
            showToast(message: "\(existingItem.name) is already on the list")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if let inCartItem = inCart.first(where: { $0.normalizedName == normalizedName }) {
            showToast(message: "\(inCartItem.name) is already in cart")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // Check suggestions - reactivate existing item instead of creating duplicate
        if let suggestionItem = suggestions.first(where: { $0.normalizedName == normalizedName }) {
            await updateItemStatus(suggestionItem, to: .active, updateAddedAt: true)
            showToast(message: "\(suggestionItem.name) added to list", type: .success)
            return
        }

        // Generate unique ID for optimistic update
        let itemId = "\(householdId)-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))"
        let now = Date()

        // Optimistic update
        let optimisticItem = GroceryItem(
            id: itemId,
            householdId: householdId,
            name: name,
            normalizedName: normalizedName,
            quantity: quantity,
            notes: notes,
            isCustom: productId == nil,
            productId: productId,
            status: .active,
            addedBy: currentUserId,
            addedAt: now,
            version: 0
        )
        items.append(optimisticItem)
        applySorting()
        pendingOptimisticIds.insert(itemId)

        do {
            // Use native createGroceryItem mutation
            let document = """
            mutation CreateGroceryItem($input: CreateGroceryItemInput!) {
                createGroceryItem(input: $input) {
                    id householdId name normalizedName quantity notes isCustom productId
                    status lockedBy addedBy addedAt version reactions
                }
            }
            """

            var input: [String: Any] = [
                "id": itemId,
                "householdId": householdId,
                "name": name,
                "normalizedName": normalizedName,
                "isCustom": productId == nil,
                "status": "ACTIVE",
                "addedBy": currentUserId,
                "addedAt": ISO8601DateFormatter().string(from: now),
                "version": 0
            ]
            if let quantity = quantity { input["quantity"] = quantity }
            if let notes = notes { input["notes"] = notes }
            if let productId = productId { input["productId"] = productId }

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   let itemJson = root["createGroceryItem"],
                   let newItem = parseGroceryItem(itemJson) {
                    // Replace optimistic item with real item
                    if let index = items.firstIndex(where: { $0.id == itemId }) {
                        items[index] = newItem
                    }
                    pendingOptimisticIds.remove(itemId)
                } else {
                    // Parsing failed - reload list
                    await loadShoppingList()
                    pendingOptimisticIds.remove(itemId)
                }
            case .failure(let error):
                // Remove optimistic item on error
                items.removeAll { $0.id == itemId }
                pendingOptimisticIds.remove(itemId)

                let errorMsg = error.localizedDescription
                if errorMsg.contains("DUPLICATE_ITEM") || errorMsg.contains("already exists") {
                    showToast(message: "\(name) is already on the list", type: .warning)
                } else {
                    showToast(message: "Error: \(errorMsg.prefix(100))", type: .error)
                }
            }
        } catch {
            // Remove optimistic item on error
            items.removeAll { $0.id == itemId }
            pendingOptimisticIds.remove(itemId)
            showToast(message: "Failed to add item", type: .error)
            print("Add item error: \(error)")
        }
    }

    // MARK: - Move Item to Cart
    func moveToCart(_ item: GroceryItem) async {
        // List is read-only for remote members during active shopping
        if isSomeoneElseShopping {
            showToast(message: "List is read-only while shopping", type: .warning)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full control)
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if !isCurrentUserShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId {
            let lockedByName = UserCache.shared.displayName(for: lockedBy)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            showToast(message: "Item is locked by \(lockedByName)", type: .warning)
            return
        }

        // Optimistic update - change status to inCart
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            updatedItem.status = .inCart
            updatedItem.version += 1

            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                items[index] = updatedItem
            }

            // Debug logging
            logger.info("Added \(item.name) to cart")
            logger.info("inCart count: \(self.inCart.count)")
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        do {
            // Use native updateGroceryItem mutation
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id householdId name normalizedName quantity notes isCustom productId
                    status lockedBy addedBy addedAt version reactions
                }
            }
            """

            let input: [String: Any] = [
                "id": item.id,
                "status": "IN_CART",
                "version": item.version + 1
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success(_):
                print("moveToCart SUCCESS - showing toast for: \(item.name)")
                showToast(message: "Added \(item.name) to cart")
            case .failure(let error):
                print("moveToCart FAILURE: \(error)")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                await loadShoppingList()
                showToast(message: "Failed to add item to cart", type: .error)
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await loadShoppingList()
            showToast(message: "Failed to add item to cart", type: .error)
            print("Move to cart error: \(error)")
        }
    }

    // MARK: - Move to Suggestion
    func moveToSuggestion(_ item: GroceryItem) async {
        // Check if locked by another user
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if let lockedBy = item.lockedBy, lockedBy != currentUserId {
            let lockedByName = UserCache.shared.displayName(for: lockedBy)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            showToast(message: "Item is locked by \(lockedByName)", type: .warning)
            return
        }

        // Optimistic update - change status to suggestion
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            updatedItem.status = .suggestion
            updatedItem.version += 1

            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                items[index] = updatedItem
                applySorting()
            }

            logger.info("Moved \(item.name) to suggestions")
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        do {
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id status version
                }
            }
            """

            let input: [String: Any] = [
                "id": item.id,
                "status": "SUGGESTION",
                "version": item.version + 1
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                showToast(message: "Moved \(item.name) to suggestions")
            case .failure(let error):
                logger.error("Move to suggestion failed: \(error)")
                await loadShoppingList()
                showToast(message: "Failed to move item", type: .error)
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await loadShoppingList()
            showToast(message: "Failed to move item", type: .error)
            print("Move to suggestion error: \(error)")
        }
    }

    // MARK: - Restore Item
    func restoreItem(_ item: GroceryItem) async {
        // List is read-only for remote members during active shopping
        if isSomeoneElseShopping {
            showToast(message: "List is read-only while shopping", type: .warning)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        let currentUserId = AmplifyService.shared.currentUser?.userId ?? ""

        // Check if locked by another user (skip during shopping mode - shopper has full control)
        if !isCurrentUserShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId {
            let lockedByName = UserCache.shared.displayName(for: lockedBy)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            showToast(message: "Item is locked by \(lockedByName)", type: .warning)
            return
        }

        // Update addedAt only when restoring from suggestion (not during shopping restore)
        let shouldUpdateAddedAt = item.status == .suggestion
        let now = Date()

        // Optimistic update - change status to active
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var restoredItem = item
            restoredItem.status = .active
            restoredItem.version += 1
            if shouldUpdateAddedAt {
                restoredItem.addedAt = now
            }

            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                items[index] = restoredItem
                applySorting()
            }
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        do {
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var input: [String: Any] = [
                "id": item.id,
                "status": "ACTIVE",
                "version": item.version + 1
            ]

            if shouldUpdateAddedAt {
                input["addedAt"] = iso8601Formatter.string(from: now)
            }

            // Use native updateGroceryItem mutation
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id householdId name normalizedName quantity notes isCustom productId
                    status lockedBy addedBy addedAt version reactions
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                showToast(message: "Restored \(item.name)")
            case .failure(let error):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                await loadShoppingList()
                showToast(message: "Failed to restore item", type: .error)
                print("Restore error: \(error)")
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await loadShoppingList()
            showToast(message: "Failed to restore item", type: .error)
            print("Restore error: \(error)")
        }
    }

    // MARK: - Delete Item
    func deleteItem(_ item: GroceryItem) async {
        // If someone else is shopping, submit a removal request instead
        if isSomeoneElseShopping {
            await submitRemoveRequest(item: item)
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full control)
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if !isCurrentUserShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId {
            let lockedByName = UserCache.shared.displayName(for: lockedBy)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            showToast(message: "Item is locked by \(lockedByName)", type: .warning)
            return
        }

        // Optimistic update
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            items.removeAll { $0.id == item.id }
        }

        // Success haptic feedback
        await MainActor.run {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        do {
            // Use native deleteGroceryItem mutation
            let document = """
            mutation DeleteGroceryItem($input: DeleteGroceryItemInput!) {
                deleteGroceryItem(input: $input) {
                    id
                }
            }
            """

            let input: [String: Any] = [
                "id": item.id
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                showToast(message: "Deleted \(item.name)")
            case .failure(let error):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                await loadShoppingList()
                showToast(message: "Failed to delete item", type: .error)
                print("Delete error: \(error)")
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await loadShoppingList()
            showToast(message: "Failed to delete item", type: .error)
            print("Delete error: \(error)")
        }
    }

    /// Suggest removal of an item to the active shopper (for remote members)
    /// This is used when someone else is shopping and a remote member wants to remove an item
    func suggestRemoval(_ item: GroceryItem) async {
        guard isSomeoneElseShopping else {
            // If not in remote shopping mode, just delete normally
            await deleteItem(item)
            return
        }

        // Get the shopper's name for the toast
        let shopperName = activeShopperDisplayName ?? "the shopper"

        // For now, show a local toast confirming the suggestion was sent
        // In a future iteration, this could notify the shopper via a real-time mechanism
        showToast(message: "Suggested removing \(item.name) to \(shopperName)", type: .info)

        // Note: The shopper will see this item in their list and can choose to cross it off
        // For a more sophisticated implementation, we could:
        // 1. Add a "removalSuggestedBy" field to the item
        // 2. Update the item via GraphQL
        // 3. The shopper would see a badge on the item indicating a removal suggestion
    }

    // MARK: - Toggle Reaction
    func toggleReaction(_ emoji: String, on item: GroceryItem) async {
        let currentUserId = AmplifyService.shared.currentUser?.userId ?? ""
        guard !currentUserId.isEmpty else {
            showToast(message: "Not signed in", type: .warning)
            return
        }

        var updatedItem = item

        // Check if user already has this reaction (toggle off)
        if let existingIndex = item.reactions.firstIndex(where: {
            $0.emoji == emoji && $0.userId == currentUserId
        }) {
            // Remove reaction
            updatedItem.reactions.remove(at: existingIndex)
        } else {
            // Add reaction
            let newReaction = ItemReaction(emoji: emoji, userId: currentUserId, addedAt: Date())
            updatedItem.reactions.append(newReaction)
        }
        updatedItem.version += 1

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = updatedItem
        }

        do {
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id reactions version
                }
            }
            """

            // Convert reactions to JSON string for AWSJSON field type
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let reactionsArray: [[String: Any]] = updatedItem.reactions.map { reaction in
                [
                    "emoji": reaction.emoji,
                    "userId": reaction.userId,
                    "addedAt": iso8601Formatter.string(from: reaction.addedAt)
                ]
            }

            // AWSJSON requires serialized JSON string
            let jsonData = try JSONSerialization.data(withJSONObject: reactionsArray)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw NSError(domain: "ShoppingList", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize reactions"])
            }

            let input: [String: Any] = [
                "id": item.id,
                "reactions": jsonString,
                "version": updatedItem.version
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                // Success - optimistic update already applied
                break
            case .failure(let error):
                // Revert optimistic update on failure
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                }
                showToast(message: "Failed to update reaction", type: .error)
                logger.error("⚠️ Reaction mutation failed: \(error)")
                logger.error("  Error description: \(error.errorDescription ?? "none")")
                logger.error("  Underlying error: \(String(describing: error.underlyingError))")
            }
        } catch {
            // Revert optimistic update on error
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            }
            showToast(message: "Failed to update reaction", type: .error)
            logger.error("⚠️ Reaction error (catch): \(error)")
            logger.error("  Localized: \(error.localizedDescription)")
        }
    }

    // MARK: - Clear My Reactions
    func clearMyReactions(from item: GroceryItem) async {
        let currentUserId = AmplifyService.shared.currentUser?.userId ?? ""
        guard !currentUserId.isEmpty else { return }

        // Check if user has any reactions to clear
        let myReactions = item.reactions.filter { $0.userId == currentUserId }
        guard !myReactions.isEmpty else { return }

        var updatedItem = item
        updatedItem.reactions.removeAll { $0.userId == currentUserId }
        updatedItem.version += 1

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = updatedItem
        }

        do {
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id reactions version
                }
            }
            """

            // Convert reactions to JSON string for AWSJSON field type
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let reactionsArray: [[String: Any]] = updatedItem.reactions.map { reaction in
                [
                    "emoji": reaction.emoji,
                    "userId": reaction.userId,
                    "addedAt": iso8601Formatter.string(from: reaction.addedAt)
                ]
            }

            let jsonData = try JSONSerialization.data(withJSONObject: reactionsArray)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw NSError(domain: "ShoppingList", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize reactions"])
            }

            let input: [String: Any] = [
                "id": item.id,
                "reactions": jsonString,
                "version": updatedItem.version
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                showToast(message: "Cleared \(myReactions.count) reaction\(myReactions.count == 1 ? "" : "s")")
            case .failure(let error):
                // Revert optimistic update
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                }
                showToast(message: "Failed to clear reactions", type: .error)
                logger.error("⚠️ Clear reactions failed: \(error)")
            }
        } catch {
            // Revert optimistic update
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            }
            showToast(message: "Failed to clear reactions", type: .error)
            logger.error("⚠️ Clear reactions error: \(error)")
        }
    }

    // MARK: - Clear All Reactions
    func clearAllReactions(from item: GroceryItem) async {
        guard !item.reactions.isEmpty else { return }

        let reactionCount = item.reactions.count
        var updatedItem = item
        updatedItem.reactions = []
        updatedItem.version += 1

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = updatedItem
        }

        do {
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id reactions version
                }
            }
            """

            // Empty array as JSON string
            let jsonString = "[]"

            let input: [String: Any] = [
                "id": item.id,
                "reactions": jsonString,
                "version": updatedItem.version
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                showToast(message: "Cleared \(reactionCount) reaction\(reactionCount == 1 ? "" : "s")")
            case .failure(let error):
                // Revert optimistic update
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                }
                showToast(message: "Failed to clear reactions", type: .error)
                logger.error("⚠️ Clear all reactions failed: \(error)")
            }
        } catch {
            // Revert optimistic update
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            }
            showToast(message: "Failed to clear reactions", type: .error)
            logger.error("⚠️ Clear all reactions error: \(error)")
        }
    }

    // MARK: - Update Notes
    func updateNotes(for item: GroceryItem, notes: String?) async {
        // Normalize empty string to nil
        let newNotes = (notes?.isEmpty == true) ? nil : notes

        // Skip if notes haven't changed
        if item.notes == newNotes { return }

        var updatedItem = item
        updatedItem.notes = newNotes
        updatedItem.version += 1

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = updatedItem
        }

        do {
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id notes version
                }
            }
            """

            var input: [String: Any] = [
                "id": item.id,
                "version": updatedItem.version
            ]

            if let newNotes = newNotes {
                input["notes"] = newNotes
            } else {
                input["notes"] = NSNull()
            }

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                logger.info("Updated notes for \(item.name)")
            case .failure(let error):
                // Revert optimistic update
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                }
                showToast(message: "Failed to update notes", type: .error)
                logger.error("Update notes failed: \(error)")
            }
        } catch {
            // Revert optimistic update
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            }
            showToast(message: "Failed to update notes", type: .error)
            logger.error("Update notes error: \(error)")
        }
    }

    // MARK: - Lock/Unlock Item
    func toggleLock(_ item: GroceryItem) async {
        // List is read-only for remote members during active shopping
        if isSomeoneElseShopping {
            showToast(message: "List is read-only while shopping", type: .warning)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        let isCurrentlyLocked = item.lockedBy != nil
        let currentUserId = AmplifyService.shared.currentUser?.userId

        // Check if locked by another user (skip during shopping mode - shopper has full control)
        if !isCurrentUserShopping, isCurrentlyLocked, let lockedBy = item.lockedBy, lockedBy != currentUserId {
            let lockedByName = UserCache.shared.displayName(for: lockedBy)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            showToast(message: "Item is locked by \(lockedByName)", type: .warning)
            return
        }

        // Success haptic feedback (using .medium for consistency with other actions)
        await MainActor.run {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        do {
            // Use native updateGroceryItem mutation
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id householdId name normalizedName quantity notes isCustom productId
                    status lockedBy addedBy addedAt version reactions
                }
            }
            """

            let newLockedBy: Any = isCurrentlyLocked ? NSNull() : (currentUserId ?? "")
            let input: [String: Any] = [
                "id": item.id,
                "lockedBy": newLockedBy,
                "version": item.version + 1
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   let itemJson = root["updateGroceryItem"],
                   let updatedItem = parseGroceryItem(itemJson) {
                    let hasLock = updatedItem.lockedBy != nil
                    let message = hasLock ? "Locked \(item.name)" : "Unlocked \(item.name)"
                    showToast(message: message)

                    // Update local state
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index] = updatedItem
                    }
                }
            case .failure(let error):
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                showToast(message: "Failed to toggle lock", type: .error)
                print("Lock error: \(error)")
            }
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showToast(message: "Failed to toggle lock", type: .error)
            print("Lock error: \(error)")
        }
    }

    // MARK: - Update Item Notes
    func updateItemNotes(_ item: GroceryItem, notes: String?) async {
        // List is read-only for remote members during active shopping
        if isSomeoneElseShopping {
            showToast(message: "List is read-only while shopping", type: .warning)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full control)
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if !isCurrentUserShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId {
            let lockedByName = UserCache.shared.displayName(for: lockedBy)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            showToast(message: "Item is locked by \(lockedByName)", type: .warning)
            return
        }

        // Store original for rollback
        let originalItem = item

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            updatedItem.notes = notes
            updatedItem.version += 1
            items[index] = updatedItem
        }

        do {
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id householdId name normalizedName quantity notes isCustom productId
                    status lockedBy addedBy addedAt version reactions
                }
            }
            """

            var input: [String: Any] = [
                "id": item.id,
                "version": item.version + 1
            ]

            // Handle nil notes by sending NSNull to clear the field
            if let notes = notes, !notes.isEmpty {
                input["notes"] = notes
            } else {
                input["notes"] = NSNull()
            }

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   let itemJson = root["updateGroceryItem"],
                   let updatedItem = parseGroceryItem(itemJson) {
                    // Update local state with server response
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index] = updatedItem
                    }
                    showToast(message: "Notes updated")
                } else {
                    // Parsing failed but mutation succeeded
                    showToast(message: "Notes updated")
                }
            case .failure(let error):
                // Rollback on failure
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = originalItem
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                showToast(message: "Failed to update notes", type: .error)
                logger.error("Update notes error: \(error)")
            }
        } catch {
            // Rollback on error
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = originalItem
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showToast(message: "Failed to update notes", type: .error)
            logger.error("Update notes error: \(error)")
        }
    }

    // MARK: - Search Products (Local Cache + Suggestions)
    func searchProducts(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count >= 2 else {
            searchResults = []
            return
        }

        // 1. Search household's SUGGESTION items first (user's previous items are more relevant)
        let matchingSuggestions = suggestions.filter { item in
            item.name.lowercased().contains(trimmed) ||
            item.normalizedName.lowercased().contains(trimmed)
        }

        // Convert matching suggestions to Product objects for display
        let suggestionProducts = matchingSuggestions.map { item in
            Product(
                id: item.id,
                name: item.name,
                normalizedName: item.normalizedName,
                category: "Previous"
            )
        }

        // 2. Search community product catalog
        let catalogProducts = ProductCache.shared.search(query: query)

        // 3. Merge results: suggestions first, then catalog (deduped by normalized name)
        var seenNames = Set(suggestionProducts.map { $0.normalizedName })
        let dedupedCatalog = catalogProducts.filter { product in
            if seenNames.contains(product.normalizedName) {
                return false
            }
            seenNames.insert(product.normalizedName)
            return true
        }

        searchResults = suggestionProducts + dedupedCatalog
    }

    // MARK: - Toggle Store Mode
    func toggleStoreMode() {
        withAnimation(.easeInOut(duration: 0.4)) {
            isAtStoreMode.toggle()

            if isAtStoreMode {
                sortByAisle()
            } else {
                applySorting()
            }
        }
    }

    // MARK: - Sorting
    func setSort(_ option: SortOption) {
        currentSort = option
        applySorting(animate: true)  // User action - animate the change
    }

    /// Apply current sort order. Only animates if explicitly requested (user changed sort).
    func applySorting(animate: Bool = false) {
        // Compute what the sorted order would be
        let sortedItems: [GroceryItem]
        switch currentSort {
        case .recentFirst:
            sortedItems = items.sorted { $0.addedAt < $1.addedAt }
        case .aToZ:
            sortedItems = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .zToA:
            sortedItems = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }

        // Check if order actually changed by comparing IDs
        let currentIds = items.map(\.id)
        let sortedIds = sortedItems.map(\.id)

        if currentIds != sortedIds {
            if animate {
                // User explicitly changed sort - animate
                withAnimation(.easeInOut(duration: 0.2)) {
                    items = sortedItems
                }
            } else {
                // Data refresh - no animation, just update silently
                items = sortedItems
            }
        }
        // If order is the same, do nothing
    }

    func sortByAisle() {
        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Subscriptions

    func setupSubscriptions() {
        guard let householdId = householdId else { return }

        // Clear any existing cancellables to avoid duplicate handlers
        subscriptionCancellables.removeAll()

        SubscriptionService.shared.subscribeToHousehold(householdId)

        // Observe created items
        SubscriptionService.shared.$lastCreatedItem
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] item in
                self?.handleItemCreated(item)
            }
            .store(in: &subscriptionCancellables)

        // Observe updated items (by ID - need to fetch full item)
        SubscriptionService.shared.$lastUpdatedItemId
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] itemId in
                Task {
                    await self?.handleItemUpdated(itemId: itemId)
                }
            }
            .store(in: &subscriptionCancellables)

        // Observe deleted items
        SubscriptionService.shared.$lastDeletedItemId
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] itemId in
                self?.handleItemDeleted(itemId: itemId)
            }
            .store(in: &subscriptionCancellables)

        // Observe household shopping status changes
        SubscriptionService.shared.$lastHouseholdShoppingUpdate
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                self?.handleHouseholdShoppingUpdate(update)
            }
            .store(in: &subscriptionCancellables)

        // Observe shopping requests
        SubscriptionService.shared.$lastShoppingRequest
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.handleNewShoppingRequest(request)
            }
            .store(in: &subscriptionCancellables)

        logger.info("Subscriptions set up for household: \(householdId)")
    }

    func teardownSubscriptions() {
        subscriptionCancellables.removeAll()
        SubscriptionService.shared.unsubscribeAll()
        logger.info("Subscriptions torn down")
    }

    // MARK: - Remote Update Helpers

    private func findItem(_ itemId: String) -> GroceryItem? {
        return items.first(where: { $0.id == itemId })
    }

    private func handleRemoteItemMovedToCart(_ item: GroceryItem) {
        let currentUserId = AmplifyService.shared.currentUser?.userId

        // Skip if this is our own action (item was already updated locally)
        if let existingItem = items.first(where: { $0.id == item.id }),
           existingItem.status == .inCart {
            return
        }

        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }

        // Mark for pending update animation
        items[index].isPendingRemoval = true
        pendingRemovals.insert(item.id)

        // Show toast
        let userName = UserCache.shared.displayName(for: item.addedBy)
        showToast(message: "added \(item.name) to cart", userName: userName)

        // Delay actual status change by 500ms for animation
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard pendingRemovals.contains(item.id) else { return }

            withAnimation(.easeOut(duration: 0.3)) {
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx] = item
                }
            }
            pendingRemovals.remove(item.id)
        }
    }

    private func applyRemoteUpdate(_ remoteItem: GroceryItem) {
        // Check for status change to show toast
        let localItem = items.first(where: { $0.id == remoteItem.id })
        let oldStatus = localItem?.status
        let statusChanged = oldStatus != remoteItem.status

        // Update item in the items array
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if let index = items.firstIndex(where: { $0.id == remoteItem.id }) {
                items[index] = remoteItem
            } else {
                // Item doesn't exist locally, add it
                items.append(remoteItem)
                applySorting()
            }
        }

        // Show toast for remote status changes
        // Note: We don't have lastModifiedBy, so we can't show who did it
        // Only show if the item existed locally (to avoid duplicate toasts on initial load)
        if statusChanged && localItem != nil {
            switch remoteItem.status {
            case .active:
                if oldStatus == .suggestion {
                    showToast(message: "\(remoteItem.name) added to list")
                }
            case .suggestion:
                showToast(message: "\(remoteItem.name) moved to suggestions")
            case .inCart:
                // Handled by handleRemoteItemMovedToCart
                break
            }
        }
    }

    private func handleHouseholdShoppingUpdate(_ update: SubscriptionService.HouseholdShoppingUpdate) {
        // Update local state from remote household update
        if let statusString = update.shoppingStatus {
            shoppingStatus = ShoppingStatus(rawValue: statusString) ?? .idle
        } else {
            shoppingStatus = .idle
        }

        activeShopperId = update.activeShopperId
        shoppingStoreId = update.shoppingStoreId

        // If someone else started shopping, show a toast
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if shoppingStatus == .atStore,
           let shopperId = activeShopperId,
           shopperId != currentUserId {
            let shopperName = UserCache.shared.displayName(for: shopperId)
            showToast(message: "is now shopping", userName: shopperName)
        }

        // If shopping ended (by someone else), show toast
        if shoppingStatus == .idle, isAtStoreMode {
            // Someone else ended the shopping session
            isAtStoreMode = false
            showToast(message: "Shopping trip ended", type: .info)
        }

        logger.info("Shopping status updated via subscription: \(self.shoppingStatus.rawValue)")
    }

    private func handleItemCreated(_ item: GroceryItem) {
        // Skip if this item was added by the current user (already applied optimistically)
        if item.addedBy == AmplifyService.shared.currentUser?.userId {
            return
        }

        // Add to items if not already present
        if !items.contains(where: { $0.id == item.id }) {
            // Create item with animating-in state for smooth appearance
            var animatingItem = item
            animatingItem.isAnimatingIn = true

            // If current user is shopping, mark this as a remotely-added item
            if isCurrentUserShopping {
                animatingItem.remoteAddedAt = Date()
            }

            // Insert with animation
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                items.append(animatingItem)
                applySorting()
            }

            // After delay, animate to full state (crossfade from skeleton)
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000) // 350ms for visible skeleton effect
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    withAnimation(.easeOut(duration: 0.35)) {
                        items[index].isAnimatingIn = false
                    }
                }
            }

            let addedByName = UserCache.shared.displayName(for: item.addedBy)
            showToast(message: "added \(item.name)", userName: addedByName)
        }
    }

    private func handleItemUpdated(itemId: String) async {
        // Skip our own optimistic updates
        if pendingOptimisticIds.contains(itemId) {
            pendingOptimisticIds.remove(itemId)
            return
        }

        // Fetch the full item from API
        guard let remoteItem = await fetchItem(id: itemId) else {
            print("handleItemUpdated: Could not fetch item \(itemId)")
            return
        }

        // Version check - ignore stale events
        if let localItem = findItem(itemId), remoteItem.version <= localItem.version {
            return
        }

        // Route to appropriate handler based on status change
        if remoteItem.status == .inCart {
            handleRemoteItemMovedToCart(remoteItem)
        } else {
            // Handle restore or other updates
            applyRemoteUpdate(remoteItem)
        }
    }

    /// Fetch a single item by ID from the API
    private func fetchItem(id: String) async -> GroceryItem? {
        let document = """
        query GetGroceryItem($id: ID!) {
            getGroceryItem(id: $id) {
                id
                householdId
                name
                normalizedName
                quantity
                notes
                isCustom
                productId
                status
                lockedBy
                addedBy
                addedAt
                version
                reactions
                images
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["id": id],
            responseType: JSONValue.self
        )

        do {
            let response = try await Amplify.API.query(request: request)
            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   let itemJson = root["getGroceryItem"] {
                    return parseGroceryItem(itemJson)
                }
            case .failure(let error):
                print("fetchItem error: \(error)")
            }
        } catch {
            print("fetchItem exception: \(error)")
        }
        return nil
    }

    private func handleItemDeleted(itemId: String) {
        let wasPresent = items.contains { $0.id == itemId }

        items.removeAll { $0.id == itemId }

        if wasPresent {
            // Item was deleted by another user
            showToast(message: "An item was removed")
        }
    }

    // MARK: - Public Toast Helpers

    /// Show lock warning when user tries to interact with item locked by another user
    func showLockedItemWarning(lockedBy userId: String) {
        let lockedByName = UserCache.shared.displayName(for: userId)
        showToast(message: "Item is locked by \(lockedByName)", type: .warning)
    }

    // MARK: - Helpers
    private func showToast(message: String, userName: String = "", type: ToastType = .success) {
        print("showToast called: '\(message)' userName: '\(userName)' type: \(type)")
        toastMessage = message
        toastUserName = userName
        toastType = type
        showToast = true

        // Errors stay longer
        let duration: UInt64 = type == .error ? 4_000_000_000 : 3_000_000_000
        Task {
            try? await Task.sleep(nanoseconds: duration)
            showToast = false
        }
    }

    // MARK: - Store Management

    /// Select a store for At Store mode
    func selectStore(_ store: Store) {
        selectedStore = store
        showToast(message: "Selected \(store.name)")
        logger.info("Selected store: \(store.name)")
    }

    /// Select a household store for At Store mode
    func selectStore(_ store: HouseholdStore) {
        selectedHouseholdStore = store
        Task {
            // Load mappings for this store
            if let mappings = try? await StoreService.shared.fetchMappings(storeId: store.id) {
                productAisleMappings[store.id] = mappings
            }
        }
        showToast(message: "Selected \(store.name)")
        logger.info("Selected store: \(store.name)")
    }

    /// Create a new store and add it to the household
    @discardableResult
    func createStore(name: String, chain: String?, aisles: [StoreAisle]) async -> HouseholdStore? {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return nil
        }

        do {
            // Create the store
            var store = try await StoreService.shared.createStore(name: name, chain: chain, householdId: householdId)

            // Add aisles to the store
            for aisle in aisles {
                store = try await StoreService.shared.addAisle(to: store, number: aisle.number, name: aisle.name)
            }

            // Update local cache
            householdStores.append(store)
            showToast(message: "Created \(name)")
            logger.info("Created store: \(name) with \(aisles.count) aisles")
            return store
        } catch {
            showToast(message: "Failed to create store", type: .error)
            logger.error("Failed to create store: \(error)")
            return nil
        }
    }

    /// Load stores for the current household
    func loadStores(forceRefresh: Bool = false) async {
        // Skip if stores already loaded (prevents redundant fetches on tab switch)
        if !householdStores.isEmpty && !forceRefresh {
            return
        }

        guard let householdId = householdId else {
            logger.error("loadStores: No household ID available")
            return
        }

        do {
            householdStores = try await StoreService.shared.fetchStores(householdId: householdId)
            logger.info("Loaded \(self.householdStores.count) stores for household")
        } catch {
            logger.error("Failed to load stores: \(error)")
        }
    }

    /// Switch to a different store during shopping
    /// Updates the household's shoppingStoreId and reloads mappings
    func switchStore(_ store: HouseholdStore) async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        // Don't switch if already at this store
        if shoppingStoreId == store.id {
            showToast(message: "Already shopping at \(store.name)", type: .info)
            return
        }

        do {
            // 1. Update Household.shoppingStoreId in backend
            let document = """
            mutation UpdateHousehold($input: UpdateHouseholdInput!) {
                updateHousehold(input: $input) {
                    id
                    shoppingStoreId
                }
            }
            """

            let input: [String: Any] = [
                "id": householdId,
                "shoppingStoreId": store.id
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                // 2. Update local shoppingStoreId
                shoppingStoreId = store.id
                selectedHouseholdStore = store

                // 3. Reload ProductAisleMappings for new store
                if let mappings = try? await StoreService.shared.fetchMappings(storeId: store.id) {
                    productAisleMappings[store.id] = mappings
                }

                // 4. Show toast
                showToast(message: "Switched to \(store.name)")
                logger.info("Switched store to: \(store.name)")

            case .failure(let error):
                showToast(message: "Failed to switch store", type: .error)
                logger.error("Failed to switch store: \(error)")
            }
        } catch {
            showToast(message: "Failed to switch store", type: .error)
            logger.error("Failed to switch store: \(error)")
        }
    }

    // MARK: - Reminder Timer Management

    /// Start reminder timer for pending shopping requests (plays notification every 45 seconds)
    func startReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.playReminderNotification()
            }
        }
    }

    /// Stop reminder timer
    func stopReminderTimer() {
        reminderTimer?.invalidate()
        reminderTimer = nil
    }

    /// Play reminder notification for pending requests
    @MainActor
    private func playReminderNotification() {
        guard pendingRequestCount > 0 else { return }
        // Play sound
        AudioServicesPlaySystemSound(1007)
        // Haptic
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Shopping Mode Management

    /// Enter shopping mode at a specific store
    func enterShoppingMode(store: HouseholdStore) async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        guard let currentUserId = AmplifyService.shared.currentUser?.userId else {
            showToast(message: "Not signed in", type: .error)
            return
        }

        do {
            // Update Household via GraphQL mutation
            let document = """
            mutation UpdateHousehold($input: UpdateHouseholdInput!) {
                updateHousehold(input: $input) {
                    id
                    shoppingStatus
                    activeShopperId
                    shoppingStoreId
                }
            }
            """

            let input: [String: Any] = [
                "id": householdId,
                "shoppingStatus": "AT_STORE",
                "activeShopperId": currentUserId,
                "shoppingStoreId": store.id
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let household) = root["updateHousehold"] {
                    // Update local state
                    if case .string(let status) = household["shoppingStatus"] {
                        shoppingStatus = status == "AT_STORE" ? .atStore : .idle
                    }
                    if case .string(let shopperId) = household["activeShopperId"] {
                        activeShopperId = shopperId
                    }
                    if case .string(let storeId) = household["shoppingStoreId"] {
                        shoppingStoreId = storeId
                    }

                    // Set selected store and start time
                    selectedHouseholdStore = store
                    shoppingStartedAt = Date()

                    // Load mappings for the store
                    if let mappings = try? await StoreService.shared.fetchMappings(storeId: store.id) {
                        productAisleMappings[store.id] = mappings
                    }

                    // Fetch pending requests
                    await fetchPendingRequests()

                    // Start reminder timer for pending requests
                    startReminderTimer()

                    showToast(message: "Shopping at \(store.name)")
                    logger.info("Entered shopping mode at store: \(store.name)")
                }
            case .failure(let error):
                showToast(message: "Failed to enter shopping mode", type: .error)
                logger.error("Failed to enter shopping mode: \(error)")
            }
        } catch {
            showToast(message: "Failed to enter shopping mode", type: .error)
            logger.error("Failed to enter shopping mode: \(error)")
        }
    }

    /// Exit shopping mode
    func exitShoppingMode(discardUncrossed: Bool) async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        do {
            // Stop reminder timer
            stopReminderTimer()

            // Calculate stats BEFORE changing item statuses
            let itemsInCart = items.filter { $0.status == .inCart }
            let itemsOnList = items.filter { $0.status == .active }
            let customItemsInCart = itemsInCart.filter { $0.isCustom }
            let storeName = selectedHouseholdStore?.name ?? "Store"
            let startTime = shoppingStartedAt ?? Date()
            let endTime = Date()

            // Create completion stats
            let stats = ShoppingCompletionStats(
                itemsPickedUp: itemsInCart.count,
                itemsNotPickedUp: discardUncrossed ? itemsOnList.count : 0,
                itemsAddedDuringTrip: 0, // TODO: Track this separately if needed
                customItemsLearned: customItemsInCart.count,
                storeName: storeName,
                startedAt: startTime,
                endedAt: endTime
            )

            // Change all inCart items to SUGGESTION status
            // Change all active items to SUGGESTION status if discardUncrossed is true
            let itemsToUpdate = discardUncrossed
                ? items.filter { $0.status == .inCart || $0.status == .active }
                : items.filter { $0.status == .inCart }

            // Batch update items to SUGGESTION status
            for item in itemsToUpdate {
                await updateItemStatus(item, to: .suggestion)
            }

            // Update Household via GraphQL mutation
            let document = """
            mutation UpdateHousehold($input: UpdateHouseholdInput!) {
                updateHousehold(input: $input) {
                    id
                    shoppingStatus
                    activeShopperId
                    shoppingStoreId
                }
            }
            """

            let input: [String: Any] = [
                "id": householdId,
                "shoppingStatus": "IDLE",
                "activeShopperId": NSNull(),
                "shoppingStoreId": NSNull()
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let household) = root["updateHousehold"] {
                    // Update local state
                    if case .string(let status) = household["shoppingStatus"] {
                        shoppingStatus = status == "AT_STORE" ? .atStore : .idle
                    }
                    activeShopperId = nil
                    shoppingStoreId = nil
                    selectedHouseholdStore = nil
                    shoppingStartedAt = nil
                    isAtStoreMode = false

                    // Clear all pending requests AFTER status is set to IDLE
                    // This prevents remote members from submitting more requests
                    await clearAllPendingRequests()

                    // Set stats and show completion sheet
                    shoppingCompletionStats = stats
                    showShoppingCompletedSheet = true

                    logger.info("Exited shopping mode - picked up \(stats.itemsPickedUp) items in \(stats.formattedDuration)")
                }
            case .failure(let error):
                showToast(message: "Failed to exit shopping mode", type: .error)
                logger.error("Failed to exit shopping mode: \(error)")
            }
        } catch {
            showToast(message: "Failed to exit shopping mode", type: .error)
            logger.error("Failed to exit shopping mode: \(error)")
        }
    }

    /// Update an item's status
    private func updateItemStatus(_ item: GroceryItem, to newStatus: GroceryItem.ItemStatus, updateAddedAt: Bool = false) async {
        let now = Date()

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            updatedItem.status = newStatus
            updatedItem.version += 1
            if updateAddedAt {
                updatedItem.addedAt = now
            }
            items[index] = updatedItem
            applySorting()
        }

        do {
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var input: [String: Any] = [
                "id": item.id,
                "status": newStatus.rawValue,
                "version": item.version + 1
            ]

            if updateAddedAt {
                input["addedAt"] = iso8601Formatter.string(from: now)
            }

            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id status version addedAt
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            _ = try await Amplify.API.mutate(request: request)
        } catch {
            logger.error("Failed to update item status: \(error)")
        }
    }

    /// Fetch current household shopping status and restore state if current user was shopping
    /// Returns true if the current user is the active shopper and UI should show AtStoreModeView
    @discardableResult
    func fetchHouseholdShoppingStatus() async -> Bool {
        guard let householdId = householdId else {
            logger.error("fetchHouseholdShoppingStatus: No household ID available")
            return false
        }

        let currentUserId = AmplifyService.shared.currentUser?.userId

        do {
            let document = """
            query GetHousehold($id: ID!) {
                getHousehold(id: $id) {
                    id
                    shoppingStatus
                    activeShopperId
                    shoppingStoreId
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["id": householdId],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.query(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let household) = root["getHousehold"] {
                    // Update local state
                    if case .string(let status) = household["shoppingStatus"] {
                        shoppingStatus = status == "AT_STORE" ? .atStore : .idle
                    } else {
                        shoppingStatus = .idle
                    }

                    if case .string(let shopperId) = household["activeShopperId"] {
                        activeShopperId = shopperId
                    } else {
                        activeShopperId = nil
                    }

                    if case .string(let storeId) = household["shoppingStoreId"] {
                        shoppingStoreId = storeId
                    } else {
                        shoppingStoreId = nil
                    }

                    logger.info("Fetched household shopping status: \(self.shoppingStatus.rawValue)")

                    // If current user is the active shopper, restore shopping mode
                    if shoppingStatus == .atStore,
                       let shopperId = activeShopperId,
                       shopperId == currentUserId {
                        isAtStoreMode = true

                        // Load the selected store
                        if let storeId = shoppingStoreId,
                           let store = householdStores.first(where: { $0.id == storeId }) {
                            selectedHouseholdStore = store

                            // Load mappings for the store
                            if let mappings = try? await StoreService.shared.fetchMappings(storeId: store.id) {
                                productAisleMappings[store.id] = mappings
                            }
                        }

                        // Fetch pending requests
                        await fetchPendingRequests()

                        // Start reminder timer for pending requests
                        startReminderTimer()

                        logger.info("Restored shopping mode for current user")
                        return true
                    }
                }
            case .failure(let error):
                logger.error("Failed to fetch household shopping status: \(error)")
            }
        } catch {
            logger.error("Failed to fetch household shopping status: \(error)")
        }

        return false
    }

    /// Assign an item to an aisle in a specific store
    func assignItemToAisle(item: GroceryItem, aisleId: String, store: HouseholdStore) async {
        do {
            try await StoreService.shared.assignProductToAisle(
                productId: item.productId,
                normalizedName: item.normalizedName,
                storeId: store.id,
                aisleId: aisleId
            )

            // Update local cache
            if productAisleMappings[store.id] == nil {
                productAisleMappings[store.id] = []
            }
            let newMapping = ProductAisleMapping(
                storeId: store.id,
                productId: item.productId,
                normalizedName: item.normalizedName,
                aisleId: aisleId
            )
            productAisleMappings[store.id]?.append(newMapping)

            showToast(message: "Assigned to aisle")
            logger.info("Assigned \(item.name) to aisle \(aisleId) in store \(store.name)")
        } catch {
            showToast(message: "Failed to assign aisle", type: .error)
            logger.error("Failed to assign item to aisle: \(error)")
        }
    }

    // MARK: - Shopping Request Management

    /// Remote member submits request to add an item
    func submitAddRequest(name: String, quantity: String? = nil, notes: String? = nil, productId: String? = nil, normalizedName: String? = nil) async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        guard let currentUserId = AmplifyService.shared.currentUser?.userId else {
            showToast(message: "Not signed in", type: .error)
            return
        }

        do {
            let document = """
            mutation CreateShoppingRequest($input: CreateShoppingRequestInput!) {
                createShoppingRequest(input: $input) {
                    id
                    householdId
                    requestType
                    itemName
                    normalizedName
                    quantity
                    notes
                    productId
                    targetItemId
                    requestedBy
                    requestedAt
                    status
                    resolvedBy
                    resolvedAt
                }
            }
            """

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let now = Date()

            var input: [String: Any] = [
                "id": UUID().uuidString,
                "householdId": householdId,
                "requestType": "ADD_ITEM",
                "itemName": name,
                "normalizedName": normalizedName ?? normalizeName(name),
                "requestedBy": currentUserId,
                "requestedAt": iso8601Formatter.string(from: now),
                "status": "PENDING"
            ]

            if let quantity = quantity { input["quantity"] = quantity }
            if let notes = notes { input["notes"] = notes }
            if let productId = productId { input["productId"] = productId }

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                let shopperName = activeShopperDisplayName ?? "shopper"
                showToast(message: "Request sent to \(shopperName)")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .failure(let error):
                showToast(message: "Failed to send request", type: .error)
                logger.error("Failed to create shopping request: \(error)")
            }
        } catch {
            showToast(message: "Failed to send request", type: .error)
            logger.error("Failed to create shopping request: \(error)")
        }
    }

    /// Remote member submits request to remove an item
    func submitRemoveRequest(item: GroceryItem) async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        guard let currentUserId = AmplifyService.shared.currentUser?.userId else {
            showToast(message: "Not signed in", type: .error)
            return
        }

        do {
            let document = """
            mutation CreateShoppingRequest($input: CreateShoppingRequestInput!) {
                createShoppingRequest(input: $input) {
                    id
                    householdId
                    requestType
                    itemName
                    normalizedName
                    quantity
                    notes
                    productId
                    targetItemId
                    requestedBy
                    requestedAt
                    status
                    resolvedBy
                    resolvedAt
                }
            }
            """

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let now = Date()

            let input: [String: Any] = [
                "id": UUID().uuidString,
                "householdId": householdId,
                "requestType": "REMOVE_ITEM",
                "itemName": item.name,
                "normalizedName": item.normalizedName ?? normalizeName(item.name),
                "targetItemId": item.id,
                "requestedBy": currentUserId,
                "requestedAt": iso8601Formatter.string(from: now),
                "status": "PENDING"
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: request)

            switch response {
            case .success:
                let shopperName = activeShopperDisplayName ?? "shopper"
                showToast(message: "Removal request sent to \(shopperName)")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .failure(let error):
                showToast(message: "Failed to send request", type: .error)
                logger.error("Failed to create shopping request: \(error)")
            }
        } catch {
            showToast(message: "Failed to send request", type: .error)
            logger.error("Failed to create shopping request: \(error)")
        }
    }

    /// Load pending requests for the current shopper
    func fetchPendingRequests() async {
        guard let householdId = householdId else { return }
        guard isCurrentUserShopping else { return }

        do {
            let document = """
            query RequestsByHouseholdAndStatus($householdId: ID!, $status: ModelStringKeyConditionInput) {
                requestsByHouseholdAndStatus(householdId: $householdId, status: $status) {
                    items {
                        id
                        householdId
                        requestType
                        itemName
                        normalizedName
                        quantity
                        notes
                        productId
                        targetItemId
                        requestedBy
                        requestedAt
                        status
                        resolvedBy
                        resolvedAt
                    }
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: [
                    "householdId": householdId,
                    "status": ["eq": "PENDING"]
                ],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.query(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let listResult) = root["requestsByHouseholdAndStatus"],
                   case .array(let items) = listResult["items"] {
                    pendingRequests = items.compactMap { parseShoppingRequest($0) }
                    logger.info("Fetched \(self.pendingRequests.count) pending requests")
                }
            case .failure(let error):
                logger.error("Failed to fetch pending requests: \(error)")
            }
        } catch {
            logger.error("Failed to fetch pending requests: \(error)")
        }
    }

    /// Shopper approves a request
    func approveRequest(_ request: ShoppingRequest) async {
        if request.isAddRequest {
            // Add the item
            await addItem(
                name: request.itemName,
                quantity: request.quantity,
                notes: request.notes,
                productId: request.productId
            )
        } else if request.isRemoveRequest, let targetItemId = request.targetItemId {
            // Find and delete the item
            if let item = items.first(where: { $0.id == targetItemId }) {
                await deleteItem(item)
            }
        }

        // Delete the request
        await deleteShoppingRequest(request)

        // Remove from local list
        pendingRequests.removeAll { $0.id == request.id }

        // Show toast
        let message = request.isAddRequest ? "Added \(request.itemName)" : "Removed \(request.itemName)"
        showToast(message: message)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Shopper rejects a request
    func rejectRequest(_ request: ShoppingRequest) async {
        // Delete the request
        await deleteShoppingRequest(request)

        // Remove from local list
        pendingRequests.removeAll { $0.id == request.id }

        // Show toast
        showToast(message: "Request rejected")
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Delete a shopping request
    private func deleteShoppingRequest(_ request: ShoppingRequest) async {
        do {
            let document = """
            mutation DeleteShoppingRequest($input: DeleteShoppingRequestInput!) {
                deleteShoppingRequest(input: $input) {
                    id
                }
            }
            """

            let input: [String: Any] = [
                "id": request.id
            ]

            let graphQLRequest = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self
            )

            let response = try await Amplify.API.mutate(request: graphQLRequest)

            switch response {
            case .success:
                logger.info("Deleted shopping request: \(request.id)")
            case .failure(let error):
                logger.error("Failed to delete shopping request: \(error)")
            }
        } catch {
            logger.error("Failed to delete shopping request: \(error)")
        }
    }

    /// Clear all pending requests (called when shopping ends)
    func clearAllPendingRequests() async {
        guard let householdId = householdId else { return }

        // Delete all pending requests for this household
        for request in pendingRequests {
            await deleteShoppingRequest(request)
        }

        // Clear local list
        pendingRequests.removeAll()
        logger.info("Cleared all pending requests for household: \(householdId)")
    }

    /// Handle new shopping request from subscription
    private func handleNewShoppingRequest(_ request: ShoppingRequest) {
        // Only add if current user is shopping
        guard isCurrentUserShopping else { return }

        // Add to pending requests if not already present
        if !pendingRequests.contains(where: { $0.id == request.id }) {
            pendingRequests.append(request)

            // Play system sound notification
            AudioServicesPlaySystemSound(1007)

            // Haptic feedback
            UINotificationFeedbackGenerator().notificationOccurred(.success)

            // Show toast
            let requesterName = UserCache.shared.displayName(for: request.requestedBy)
            let message = request.isAddRequest ? "wants to add \(request.itemName)" : "wants to remove \(request.itemName)"
            showToast(message: message, userName: requesterName)

            logger.info("New shopping request received: \(request.itemName) from \(requesterName)")
        }
    }

    // MARK: - Image Management

    /// Upload an image for a grocery item to S3 and update the item record
    func uploadItemImage(for item: GroceryItem, imageData: Data) async throws {
        guard item.images.count < 5 else {
            throw NSError(domain: "ImageError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Maximum 5 images allowed"])
        }

        guard let currentUserId = AmplifyService.shared.currentUser?.userId else {
            throw NSError(domain: "ImageError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }

        let imageId = UUID().uuidString
        let s3Key = "item-images/\(item.householdId)_\(item.id)_\(imageId).jpg"

        logger.info("Uploading image with key: \(s3Key)")
        logger.info("Image data size: \(imageData.count) bytes")

        // Upload to S3
        let uploadTask = Amplify.Storage.uploadData(
            path: .fromString(s3Key),
            data: imageData,
            options: .init(contentType: "image/jpeg")
        )

        _ = try await uploadTask.value

        // Create ItemImage metadata
        let newImage = ItemImage(
            id: imageId,
            s3Key: s3Key,
            uploadedBy: currentUserId,
            uploadedAt: Date()
        )

        // Update item with new image
        var updatedImages = item.images
        updatedImages.append(newImage)

        try await updateItemImages(itemId: item.id, images: updatedImages)

        // Update local state
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].images = updatedImages
        }

        showToast(message: "Image uploaded")
        logger.info("Uploaded image for item: \(item.name)")
    }

    /// Delete an image from S3 and update the item record
    func deleteItemImage(from item: GroceryItem, imageId: String) async throws {
        guard let imageToDelete = item.images.first(where: { $0.id == imageId }) else {
            throw NSError(domain: "ImageError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image not found"])
        }

        // Delete from S3
        try await Amplify.Storage.remove(path: .fromString(imageToDelete.s3Key))

        // Update item with filtered images array
        let updatedImages = item.images.filter { $0.id != imageId }

        try await updateItemImages(itemId: item.id, images: updatedImages)

        // Update local state
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].images = updatedImages
        }

        showToast(message: "Image deleted")
        logger.info("Deleted image from item: \(item.name)")
    }

    /// Download an image from S3
    func downloadItemImage(s3Key: String) async throws -> Data {
        let downloadTask = Amplify.Storage.downloadData(path: .fromString(s3Key))
        let data = try await downloadTask.value
        return data
    }

    /// Helper to update the images field in the backend
    private func updateItemImages(itemId: String, images: [ItemImage]) async throws {
        let document = """
        mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
            updateGroceryItem(input: $input) {
                id images version
            }
        }
        """

        // Convert images to JSON string for AWSJSON field type
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let imagesArray: [[String: Any]] = images.map { image in
            [
                "id": image.id,
                "s3Key": image.s3Key,
                "uploadedBy": image.uploadedBy,
                "uploadedAt": iso8601Formatter.string(from: image.uploadedAt)
            ]
        }

        // AWSJSON requires serialized JSON string
        let jsonData = try JSONSerialization.data(withJSONObject: imagesArray)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw NSError(domain: "ImageError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize images"])
        }

        let input: [String: Any] = [
            "id": itemId,
            "images": jsonString
        ]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success:
            logger.info("Updated images for item: \(itemId)")
        case .failure(let error):
            logger.error("Failed to update images: \(error)")
            throw error
        }
    }

    // MARK: - Parsing Helpers
    func parseGroceryItem(_ json: JSONValue) -> GroceryItem? {
        guard case .object(let obj) = json,
              case .string(let id) = obj["id"],
              case .string(let householdId) = obj["householdId"],
              case .string(let name) = obj["name"],
              case .boolean(let isCustom) = obj["isCustom"],
              case .string(let statusString) = obj["status"],
              case .string(let addedBy) = obj["addedBy"] else {
            print("parseGroceryItem: Missing required field in JSON: \(json)")
            return nil
        }

        // Parse status - handle all three status values
        let status: GroceryItem.ItemStatus
        switch statusString {
        case "ACTIVE":
            status = .active
        case "IN_CART":
            status = .inCart
        case "SUGGESTION":
            status = .suggestion
        default:
            // Fallback: treat unknown as active
            status = .active
        }

        var addedAt = Date()
        if case .string(let addedAtString) = obj["addedAt"] {
            addedAt = ISO8601DateFormatter().date(from: addedAtString) ?? Date()
        }

        var normalizedName: String? = nil
        if case .string(let value) = obj["normalizedName"] { normalizedName = value }

        var quantity: String? = nil
        if case .string(let value) = obj["quantity"] { quantity = value }

        var notes: String? = nil
        if case .string(let value) = obj["notes"] { notes = value }

        var productId: String? = nil
        if case .string(let value) = obj["productId"] { productId = value }

        var lockedBy: String? = nil
        if case .string(let value) = obj["lockedBy"] { lockedBy = value }

        var version: Int = 0
        if case .number(let value) = obj["version"] { version = Int(value) }

        // Parse reactions from JSON string
        var reactions: [ItemReaction] = []
        if case .string(let reactionsString) = obj["reactions"],
           let data = reactionsString.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            reactions = (try? decoder.decode([ItemReaction].self, from: data)) ?? []
        }

        // Parse images (AWSJSON field)
        var images: [ItemImage] = []
        if case .string(let imagesString) = obj["images"],
           let data = imagesString.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            images = (try? decoder.decode([ItemImage].self, from: data)) ?? []
        }

        return GroceryItem(
            id: id,
            householdId: householdId,
            name: name,
            normalizedName: normalizedName,
            quantity: quantity,
            notes: notes,
            isCustom: isCustom,
            productId: productId,
            status: status,
            lockedBy: lockedBy,
            addedBy: addedBy,
            addedAt: addedAt,
            version: version,
            reactions: reactions,
            images: images
        )
    }

    func parseProduct(_ json: JSONValue) -> Product? {
        guard case .object(let obj) = json,
              case .string(let id) = obj["id"],
              case .string(let name) = obj["name"],
              case .string(let category) = obj["category"] else {
            return nil
        }

        var normalizedName = name.lowercased()
        if case .string(let value) = obj["normalizedName"] { normalizedName = value }

        var aliases: [String] = []
        if case .array(let aliasArray) = obj["aliases"] {
            aliases = aliasArray.compactMap { value in
                if case .string(let str) = value { return str }
                return nil
            }
        }

        return Product(
            id: id,
            name: name,
            normalizedName: normalizedName,
            aliases: aliases,
            category: category
        )
    }

    func parseShoppingRequest(_ json: JSONValue) -> ShoppingRequest? {
        guard case .object(let obj) = json,
              case .string(let id) = obj["id"],
              case .string(let householdId) = obj["householdId"],
              case .string(let requestTypeString) = obj["requestType"],
              case .string(let itemName) = obj["itemName"],
              case .string(let requestedBy) = obj["requestedBy"],
              case .string(let statusString) = obj["status"] else {
            logger.error("parseShoppingRequest: Missing required field in JSON")
            return nil
        }

        guard let requestType = ShoppingRequest.RequestType(rawValue: requestTypeString),
              let status = ShoppingRequest.RequestStatus(rawValue: statusString) else {
            logger.error("parseShoppingRequest: Invalid enum value - requestType: \(requestTypeString), status: \(statusString)")
            return nil
        }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var requestedAt = Date()
        if case .string(let requestedAtString) = obj["requestedAt"] {
            requestedAt = iso8601Formatter.date(from: requestedAtString) ?? Date()
        }

        var resolvedAt: Date? = nil
        if case .string(let resolvedAtString) = obj["resolvedAt"] {
            resolvedAt = iso8601Formatter.date(from: resolvedAtString)
        }

        var normalizedName: String? = nil
        if case .string(let value) = obj["normalizedName"] { normalizedName = value }

        var quantity: String? = nil
        if case .string(let value) = obj["quantity"] { quantity = value }

        var notes: String? = nil
        if case .string(let value) = obj["notes"] { notes = value }

        var productId: String? = nil
        if case .string(let value) = obj["productId"] { productId = value }

        var targetItemId: String? = nil
        if case .string(let value) = obj["targetItemId"] { targetItemId = value }

        var resolvedBy: String? = nil
        if case .string(let value) = obj["resolvedBy"] { resolvedBy = value }

        return ShoppingRequest(
            id: id,
            householdId: householdId,
            requestType: requestType,
            itemName: itemName,
            normalizedName: normalizedName,
            quantity: quantity,
            notes: notes,
            productId: productId,
            targetItemId: targetItemId,
            requestedBy: requestedBy,
            requestedAt: requestedAt,
            status: status,
            resolvedBy: resolvedBy,
            resolvedAt: resolvedAt
        )
    }
}
