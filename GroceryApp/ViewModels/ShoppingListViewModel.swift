import SwiftUI
import Combine
import Amplify
import AWSPluginsCore
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
    /// A store-less errand run. Startable only from `.idle`, so it never races a store trip.
    case adHoc = "AD_HOC"
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

    /// Tick that drives time-based UI (e.g. "session abandoned" banner). Updated once per minute while at-store.
    @Published var abandonedCheckTick: Date = Date()
    private var abandonedCheckTimer: Timer?

    /// After this many seconds without the shopper finishing, other members can force-finish.
    static let abandonedShoppingThreshold: TimeInterval = 60 * 60  // 1 hour
    static let shopperInactivityReminder: TimeInterval = 10 * 60   // 10 minutes

    // MARK: - Shopping Request Inbox
    @Published var pendingRequests: [ShoppingRequest] = []
    @Published var showInboxSheet = false

    // MARK: - Undo Cart
    @Published var undoCartItem: GroceryItem?
    private var undoCartTask: Task<Void, Never>?

    // MARK: - Undo Suggestion
    @Published var undoSuggestionItem: GroceryItem?
    private var undoSuggestionTask: Task<Void, Never>?

    // MARK: - Wakeup Interaction Lock
    /// Briefly true after app returns from background to prevent accidental taps
    @Published var isInteractionLocked: Bool = false

    // MARK: - Computed Properties for Filtered Views

    /// Items on the shopping list (active items to be picked up)
    var shoppingList: [GroceryItem] {
        items.filter { $0.status == .active && !$0.adHoc }
    }

    /// Items already in the cart during the current shopping trip
    var inCart: [GroceryItem] {
        items.filter { $0.status == .inCart && !$0.adHoc }
    }

    /// Suggested items from previous shopping trips
    var suggestions: [GroceryItem] {
        items.filter { $0.status == .suggestion }
    }

    // MARK: - Ad-Hoc Trip

    /// Items still to grab on the current store-less errand
    var adHocList: [GroceryItem] {
        items.filter { $0.status == .active && $0.adHoc }
    }

    /// Items already grabbed on the current errand
    var adHocInCart: [GroceryItem] {
        items.filter { $0.status == .inCart && $0.adHoc }
    }

    /// True while this household is on a store-less errand
    var isAdHocMode: Bool {
        shoppingStatus == .adHoc
    }

    /// True when the current user is the one running the errand
    var isCurrentUserAdHocShopping: Bool {
        guard shoppingStatus == .adHoc,
              let shopperId = activeShopperId,
              let currentUserId = AmplifyService.shared.currentUser?.userId else {
            return false
        }
        return shopperId == currentUserId
    }

    /// True while another member holds an active session of any kind, so this
    /// device must not mutate the list. Two people editing while one of them is
    /// standing in an aisle produces races nobody can reason about — and for a
    /// two-person household, "text them" is a better channel than a live edit.
    var isListLockedByOtherSession: Bool {
        isSomeoneElseShopping || isSomeoneElseAdHocShopping
    }

    /// True when another member is out on an errand
    var isSomeoneElseAdHocShopping: Bool {
        guard shoppingStatus == .adHoc,
              let shopperId = activeShopperId,
              let currentUserId = AmplifyService.shared.currentUser?.userId else {
            return false
        }
        return shopperId != currentUserId
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

    /// Seconds elapsed since shopping started (nil when not shopping).
    /// Re-evaluates whenever `abandonedCheckTick` fires.
    var shoppingElapsed: TimeInterval? {
        guard let startedAt = shoppingStartedAt else { return nil }
        _ = abandonedCheckTick
        return Date().timeIntervalSince(startedAt)
    }

    /// True when someone else is shopping and the session has exceeded the abandoned threshold.
    /// Only surfaced to non-shoppers — the shopper themselves ends their own session.
    var isSessionAbandoned: Bool {
        guard isSomeoneElseShopping,
              let elapsed = shoppingElapsed else { return false }
        return elapsed >= Self.abandonedShoppingThreshold
    }

    /// Human-readable elapsed time like "1h 23m" for banner/alert text.
    var shoppingElapsedDescription: String? {
        guard let elapsed = shoppingElapsed else { return nil }
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
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
        // Load the local copy first, synchronously, before anything that can
        // fail. If Amplify never configures and the network never answers, the
        // list is already on screen by the time either of those matters.
        restoreLocalSnapshot()
        setupHouseholdChangeObserver()
        setupLocalSnapshotSaving()
    }

    // MARK: - Local Snapshot

    /// True when the list on screen came from disk and hasn't been refreshed
    /// from the server yet — the cue for telling the user what they're looking at.
    @Published private(set) var isShowingLocalSnapshot = false
    @Published private(set) var localSnapshotSavedAt: Date?

    private func restoreLocalSnapshot() {
        guard let snapshot = LocalListStore.load(), !snapshot.items.isEmpty else { return }
        items = snapshot.items
        localSnapshotSavedAt = snapshot.savedAt
        isShowingLocalSnapshot = true
        logger.info("Restored \(snapshot.items.count) items from local snapshot")
    }

    private func setupLocalSnapshotSaving() {
        // Debounced so a burst of edits writes once, not once per keystroke.
        $items
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] items in
                LocalListStore.save(items: items, householdId: self?.householdId)
            }
            .store(in: &cancellables)
    }

    deinit {
        if let observer = householdChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        reminderTimer?.invalidate()
        abandonedCheckTimer?.invalidate()
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

    // MARK: - Network Gate

    /// Every network call in this view model goes through these two wrappers, so
    /// paper mode has exactly one place to stop them. Twenty scattered guards
    /// would drift apart the first time someone adds a mutation and forgets one.
    private func apiMutate(_ request: GraphQLRequest<JSONValue>) async throws -> GraphQLResponse<JSONValue> {
        guard !PaperMode.shared.blocksNetwork else { throw PaperModeActive() }
        return try await Amplify.API.mutate(request: request)
    }

    private func apiQuery(_ request: GraphQLRequest<JSONValue>) async throws -> GraphQLResponse<JSONValue> {
        guard !PaperMode.shared.blocksNetwork else { throw PaperModeActive() }
        return try await Amplify.API.query(request: request)
    }

    // MARK: - Data Loading
    func loadShoppingList(forceRefresh: Bool = false) async {
        // Paper mode: the local copy is the list. Don't fetch, don't wait, don't
        // spin — just keep showing what's already on screen.
        if PaperMode.shared.blocksNetwork {
            hasLoadedInitialData = true
            return
        }

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
                        notesEphemeral
                        adHoc
                        adHocPulled
                        isCustom
                        productId
                        status
                        lockedBy
                        addedBy
                        addedAt
                        version
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiQuery(request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let listResult) = root["listGroceryItems"],
                   case .array(let itemsJson) = listResult["items"] {
                    self.items = itemsJson.compactMap { parseGroceryItem($0) }
                    applySorting()
                    isShowingLocalSnapshot = false

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
                handleServerUnreachable()
            }

        } catch {
            logger.error("Error loading shopping list: \(error)")
            errorMessage = error.localizedDescription
            AmplifyService.shared.handleAuthError(error)
            handleServerUnreachable()
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
        // Someone else is mid-trip: ask rather than either blocking or barging in.
        // A hard block ignores that they may still be in the aisles; a direct add
        // (the v1.3.0 behaviour) ignores that they may be at the checkout. Only
        // the person actually standing there can judge, so let them decide.
        if isListLockedByOtherSession {
            await submitAddRequest(name: name, quantity: quantity, notes: notes, productId: productId)
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

        // Check for duplicates in cached list (exact normalized-name match only —
        // fuzzy token-subset matching is deliberately restricted to the bulk-import
        // review picker, where the user gets to accept/reject each candidate. Silent
        // auto-merge risks buying the wrong thing, e.g. "coconut milk" collapsing
        // into "coconut milk yogurt".)
        // During an errand the item belongs to that trip, and duplicates are checked
        // against the errand's own lists — the main list is a separate world right now.
        let isErrandAdd = isAdHocMode
        let normalizedName = normalizeName(name)
        let listToCheck = isErrandAdd ? adHocList : shoppingList
        let cartToCheck = isErrandAdd ? adHocInCart : inCart

        if let existingItem = listToCheck.first(where: { $0.normalizedName == normalizedName }) {
            showToast(message: "\(existingItem.name) is already on the list")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if let inCartItem = cartToCheck.first(where: { $0.normalizedName == normalizedName }) {
            showToast(message: "\(inCartItem.name) is already in cart")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // On an errand, an item sitting on the main list is pulled onto the trip rather
        // than duplicated — this is the "add from item list" path the user wanted.
        if isErrandAdd, let mainListItem = shoppingList.first(where: { $0.normalizedName == normalizedName }) {
            await pullItemToAdHoc(mainListItem)
            return
        }

        // Check suggestions - reactivate existing item instead of creating duplicate
        if let suggestionItem = suggestions.first(where: { $0.normalizedName == normalizedName }) {
            await setAdHocFlags(suggestionItem, adHoc: isErrandAdd, pulled: false, status: .active)
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
            adHoc: isErrandAdd,
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
                    id householdId name normalizedName quantity notes notesEphemeral adHoc adHocPulled isCustom productId
                    status lockedBy addedBy addedAt version
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
                "adHoc": isErrandAdd,
                "version": 0
            ]
            if let quantity = quantity { input["quantity"] = quantity }
            if let notes = notes { input["notes"] = notes }
            if let productId = productId { input["productId"] = productId }

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
            // On paper the item stays. Deleting what the user just typed because
            // we couldn't reach a server would be the worst bug in the mode.
            if error is PaperModeActive {
                pendingOptimisticIds.remove(itemId)
                return
            }
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
        if isListLockedByOtherSession {
            showToast(message: "List is read-only while shopping", type: .warning)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full
        // control, and likewise for the runner of a store-less errand)
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if !isCurrentUserShopping, !isCurrentUserAdHocShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId {
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

        // Set undo state — clears after 5.5 seconds
        undoCartItem = item
        undoCartTask?.cancel()
        undoCartTask = Task {
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            if !Task.isCancelled {
                undoCartItem = nil
            }
        }

        do {
            // Use native updateGroceryItem mutation
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id householdId name normalizedName quantity notes notesEphemeral adHoc adHocPulled isCustom productId
                    status lockedBy addedBy addedAt version
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

            switch response {
            case .success(_):
                print("moveToCart SUCCESS - showing toast for: \(item.name)")
                showToast(message: "Added \(item.name) to cart")
                bumpShopperActivity()
            case .failure(let error):
                print("moveToCart FAILURE: \(error)")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                await loadShoppingList()
                showToast(message: "Failed to add item to cart", type: .error)
            }
        } catch {
            // On paper the cross-off stands — no error buzz, no resync.
            if error is PaperModeActive { return }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await loadShoppingList()
            showToast(message: "Failed to add item to cart", type: .error)
            print("Move to cart error: \(error)")
        }
    }

    // MARK: - Undo Move to Cart
    func undoMoveToCart() async {
        guard let item = undoCartItem else { return }
        undoCartTask?.cancel()
        undoCartItem = nil
        await restoreItem(item)
    }

    // MARK: - Undo Move to Suggestion
    func undoMoveToSuggestion() async {
        guard let item = undoSuggestionItem else { return }
        undoSuggestionTask?.cancel()
        undoSuggestionItem = nil
        await restoreItem(item)
    }

    // MARK: - Wakeup Interaction Lock
    func lockInteractionsOnWakeup() {
        isInteractionLocked = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
            isInteractionLocked = false
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

        let now = Date()

        // Optimistic update - change status to suggestion, refresh addedAt so it sorts to top
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            updatedItem.status = .suggestion
            updatedItem.addedAt = now
            updatedItem.version += 1

            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                items[index] = updatedItem
                applySorting()
            }

            logger.info("Moved \(item.name) to suggestions")
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Set undo state — clears after 5.5 seconds
        undoSuggestionItem = item
        undoSuggestionTask?.cancel()
        undoSuggestionTask = Task {
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            if !Task.isCancelled {
                undoSuggestionItem = nil
            }
        }

        do {
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id status addedAt version
                }
            }
            """

            let input: [String: Any] = [
                "id": item.id,
                "status": "SUGGESTION",
                "addedAt": iso8601Formatter.string(from: now),
                "version": item.version + 1
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
        // Same reasoning as addItem: pulling a suggestion back onto the list
        // during someone else's trip is a request, not a fait accompli.
        if isListLockedByOtherSession {
            await submitAddRequest(
                name: item.name,
                quantity: item.quantity,
                notes: item.notes,
                productId: item.productId,
                normalizedName: item.normalizedName
            )
            return
        }

        // On an errand, a suggestion joins the errand rather than the main list.
        if isCurrentUserAdHocShopping && !item.adHoc {
            await setAdHocFlags(item, adHoc: true, pulled: false, status: .active)
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

        // Optimistic update - change status to active, update addedBy to whoever restored it
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var restoredItem = item
            restoredItem.status = .active
            restoredItem.addedBy = currentUserId
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
                "addedBy": currentUserId,
                "version": item.version + 1
            ]

            if shouldUpdateAddedAt {
                input["addedAt"] = iso8601Formatter.string(from: now)
            }

            // Use native updateGroceryItem mutation
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id householdId name normalizedName quantity notes notesEphemeral adHoc adHocPulled isCustom productId
                    status lockedBy addedBy addedAt version
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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

        // Check if locked by another user (skip during shopping mode - shopper has full
        // control, and likewise for the runner of a store-less errand)
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if !isCurrentUserShopping, !isCurrentUserAdHocShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId {
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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

    // MARK: - Update Notes
    func updateNotes(for item: GroceryItem, notes: String?, ephemeral: Bool = false) async {
        // Normalize empty string to nil
        let newNotes = (notes?.isEmpty == true) ? nil : notes
        // A cleared note carries no lifetime
        let newEphemeral = newNotes == nil ? false : ephemeral

        // Skip if nothing changed
        if item.notes == newNotes && item.notesEphemeral == newEphemeral { return }

        var updatedItem = item
        updatedItem.notes = newNotes
        updatedItem.notesEphemeral = newEphemeral
        updatedItem.version += 1

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = updatedItem
        }

        do {
            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id notes notesEphemeral version
                }
            }
            """

            var input: [String: Any] = [
                "id": item.id,
                "notesEphemeral": newEphemeral,
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
            // On paper the local edit stands — it's the whole point of the mode.
            if error is PaperModeActive { return }
            // Revert optimistic update
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            }
            showToast(message: "Failed to update notes", type: .error)
            logger.error("Update notes error: \(error)")
        }
    }

    /// Wipe every trip-scoped note in the household. Called when a shopping session
    /// finishes — the note was written for that trip and shouldn't survive into the next.
    private func clearEphemeralNotes() async {
        let itemsToClear = items.filter { $0.notesEphemeral && $0.notes != nil }
        guard !itemsToClear.isEmpty else { return }

        for item in itemsToClear {
            await updateNotes(for: item, notes: nil)
        }
        logger.info("Cleared \(itemsToClear.count) trip-scoped notes")
    }

    // MARK: - Lock/Unlock Item
    func toggleLock(_ item: GroceryItem) async {
        // List is read-only for remote members during active shopping
        if isListLockedByOtherSession {
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
                    id householdId name normalizedName quantity notes notesEphemeral adHoc adHocPulled isCustom productId
                    status lockedBy addedBy addedAt version
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
        if isListLockedByOtherSession {
            showToast(message: "List is read-only while shopping", type: .warning)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full
        // control, and likewise for the runner of a store-less errand)
        let currentUserId = AmplifyService.shared.currentUser?.userId
        if !isCurrentUserShopping, !isCurrentUserAdHocShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId {
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
                    id householdId name normalizedName quantity notes notesEphemeral adHoc adHocPulled isCustom productId
                    status lockedBy addedBy addedAt version
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
        // addedAt has only 1-second precision (ISO8601DateFormatter default), so items
        // added within the same second tie. Break ties on id so order stays identical
        // across refreshes instead of following the backend's unordered scan result,
        // which otherwise reshuffles those items every time the list is refetched.
        let sortedItems: [GroceryItem]
        switch currentSort {
        case .recentFirst:
            sortedItems = items.sorted {
                if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
                return $0.id < $1.id
            }
        case .aToZ:
            sortedItems = items.sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.id < $1.id
            }
        case .zToA:
            sortedItems = items.sorted {
                let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
                if comparison != .orderedSame { return comparison == .orderedDescending }
                return $0.id < $1.id
            }
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
        // A GraphQL socket retrying its handshake forever is exactly the hang
        // paper mode exists to prevent, so don't open one.
        guard !PaperMode.shared.blocksNetwork else { return }
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

    // MARK: - Server Unreachable

    /// Set when we couldn't reach the server but do have a local copy to shop from.
    @Published var showOfflinePrompt = false
    /// True while quietly retrying after the user declined paper mode.
    @Published private(set) var isRetryingConnection = false

    private var offeredPaperThisLaunch = false
    private var reconnectTask: Task<Void, Never>?

    /// The crash-at-the-store case: we came up, couldn't reach anything, but the
    /// local snapshot means there IS a list to shop from. Offer it rather than
    /// leaving the user staring at an empty screen.
    private func handleServerUnreachable() {
        guard !PaperMode.shared.blocksNetwork else { return }
        guard !offeredPaperThisLaunch else { return }
        guard !items.isEmpty else { return }   // nothing to offer

        offeredPaperThisLaunch = true
        showOfflinePrompt = true
    }

    /// User said no to paper. Keep trying — store wifi often shows up a minute
    /// later, and they shouldn't have to think about it again.
    func keepTryingToReconnect() {
        guard reconnectTask == nil else { return }
        isRetryingConnection = true

        reconnectTask = Task { @MainActor in
            while !Task.isCancelled && isRetryingConnection {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled || PaperMode.shared.blocksNetwork { break }

                await loadShoppingList(forceRefresh: true)

                if !isShowingLocalSnapshot {
                    // A real fetch landed — we're back.
                    isRetryingConnection = false
                    showToast(message: "Back online", type: .success)
                    setupSubscriptions()
                    break
                }
            }
            reconnectTask = nil
        }
    }

    func stopRetryingToReconnect() {
        isRetryingConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    // MARK: - Paper List Mode

    /// Go to paper. Everything that reaches the network stops here — not just
    /// mutations, but the live sockets and the interval timers behind them.
    func enterPaperMode() {
        PaperMode.shared.enter()
        stopRetryingToReconnect()

        teardownSubscriptions()
        stopReminderTimer()
        stopAbandonedCheckTimer()
        ShopperReminderService.shared.cancel()

        // Whatever is on screen right now becomes the paper list.
        LocalListStore.save(items: items, householdId: householdId)
        localSnapshotSavedAt = Date()

        logger.info("Entered paper mode with \(self.items.count) items")
    }

    /// Come back to normal operation. Deliberately does not push anything —
    /// applying a paper trip is a separate, user-approved step.
    func exitPaperMode() async {
        PaperMode.shared.exit()
        logger.info("Left paper mode")

        await loadShoppingList(forceRefresh: true)
        await loadStores(forceRefresh: true)
        setupSubscriptions()
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

        // Track session start so non-shoppers can detect an abandoned session.
        if shoppingStatus == .atStore {
            if let startedAt = update.shoppingStartedAt {
                shoppingStartedAt = startedAt
            } else if shoppingStartedAt == nil {
                // Session started by an app version that didn't write the field —
                // fall back to when we first observed it.
                shoppingStartedAt = Date()
            }
        } else {
            shoppingStartedAt = nil
        }

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
            ShopperReminderService.shared.cancel()
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
                notesEphemeral
                adHoc
                adHocPulled
                isCustom
                productId
                status
                lockedBy
                addedBy
                addedAt
                version
                images
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["id": id],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        do {
            let response = try await apiQuery(request)
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
        // On paper, a write never reaching the server is the design, not a fault.
        // Reporting it as an error would tell the user something broke when
        // nothing did — and it would fire on essentially every tap.
        if PaperMode.shared.blocksNetwork && type == .error { return }

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
    func createStore(name: String, chain: String?, aisles: [StoreAisle], layoutType: StoreLayoutType = .aisles) async -> HouseholdStore? {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return nil
        }

        do {
            // Create the store
            var store = try await StoreService.shared.createStore(name: name, chain: chain, householdId: householdId, layoutType: layoutType)

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

            if householdStores.isEmpty {
                await createDefaultStore()
            }
        } catch {
            logger.error("Failed to load stores: \(error)")
        }
    }

    /// Every household gets one plain store so "At Store" is never blocked behind
    /// setup. No aisles defined — the map fills itself in as items get assigned
    /// while shopping, rather than being declared up front.
    private func createDefaultStore() async {
        guard !PaperMode.shared.blocksNetwork else { return }

        logger.info("No stores for this household — creating the default one")
        _ = await createStore(
            name: Self.defaultStoreName,
            chain: nil,
            aisles: [],
            layoutType: .noAisles
        )
    }

    static let defaultStoreName = "My Store"

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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
        guard !PaperMode.shared.blocksNetwork else { return }
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

    /// Start a 60s tick that lets the UI re-evaluate `isSessionAbandoned` while at-store.
    func startAbandonedCheckTimer() {
        abandonedCheckTimer?.invalidate()
        abandonedCheckTick = Date()
        abandonedCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.abandonedCheckTick = Date()
            }
        }
    }

    func stopAbandonedCheckTimer() {
        abandonedCheckTimer?.invalidate()
        abandonedCheckTimer = nil
    }

    /// Push the shopper-inactivity reminder out to `shopperInactivityReminder` from now.
    /// Called on session start and on every successful `moveToCart` — silent no-op
    /// if the current user is not the active shopper.
    func bumpShopperActivity() {
        guard isCurrentUserShopping else { return }
        ShopperReminderService.shared.schedule(after: Self.shopperInactivityReminder)
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
                    shoppingStartedAt
                }
            }
            """

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let input: [String: Any] = [
                "id": householdId,
                "shoppingStatus": "AT_STORE",
                "activeShopperId": currentUserId,
                "shoppingStoreId": store.id,
                "shoppingStartedAt": iso8601Formatter.string(from: Date())
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let household) = root["updateHousehold"] {
                    // Update local state
                    if case .string(let status) = household["shoppingStatus"] {
                        shoppingStatus = ShoppingStatus(rawValue: status) ?? .idle
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

                        // Infer aisles for custom active items with no existing mapping.
                        // Only stores that actually navigate by aisle are worth the LLM spend:
                        // a NO_AISLES store has nothing to infer, and an empty aisleLayout means
                        // there are no aisles to infer *against*, so the guesses are pure noise
                        // (and get persisted as phantom mappings).
                        let mappedNames = Set(mappings.compactMap { $0.normalizedName })
                        let unmappedCustomItems = items.filter { item in
                            item.isCustom && item.status == .active && !mappedNames.contains(item.normalizedName)
                        }
                        if !store.supportsAisleNavigation {
                            logger.info("At-Store pre-check: skipped aisle inference (store has no aisle layout)")
                        } else if !unmappedCustomItems.isEmpty {
                            let batchInputs = unmappedCustomItems.map {
                                AisleExtractionService.BatchInferenceInput(
                                    id: $0.id,
                                    productName: $0.name,
                                    normalizedName: $0.normalizedName,
                                    productId: nil
                                )
                            }
                            if let results = try? await AisleExtractionService.shared.inferProductAisleBatch(
                                storeId: store.id,
                                items: batchInputs
                            ) {
                                let saved = try? await AisleExtractionService.shared.saveBatchInferenceResults(
                                    items: batchInputs,
                                    results: results,
                                    storeId: store.id
                                )
                                logger.info("At-Store pre-check: inferred aisles for \(saved ?? 0) custom items")
                                // Refresh mappings to include newly saved inferences
                                if let refreshed = try? await StoreService.shared.fetchMappings(storeId: store.id) {
                                    productAisleMappings[store.id] = refreshed
                                }
                            }
                        }
                    }

                    // Fetch pending requests
                    await fetchPendingRequests()

                    // Start reminder timer for pending requests
                    startReminderTimer()

                    // Nudge the shopper if nothing gets crossed off for a while.
                    await ShopperReminderService.shared.requestPermissionIfNeeded()
                    bumpShopperActivity()

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
            ShopperReminderService.shared.cancel()

            // Calculate stats BEFORE changing item statuses
            let itemsInCart = inCart
            let itemsOnList = shoppingList
            let customItemsInCart = itemsInCart.filter { $0.isCustom }
            let storeName = selectedHouseholdStore?.name ?? "Store"
            let startTime = shoppingStartedAt ?? Date()
            let endTime = Date()

            // Create completion stats
            let stats = ShoppingCompletionStats(
                itemsPickedUp: itemsInCart.count,
                // Left behind either way — keeping them doesn't make them bought.
                itemsNotPickedUp: itemsOnList.count,
                itemsAddedDuringTrip: 0, // TODO: Track this separately if needed
                customItemsLearned: customItemsInCart.count,
                storeName: storeName,
                startedAt: startTime,
                endedAt: endTime
            )

            // Change all inCart items to SUGGESTION status
            // Change all active items to SUGGESTION status if discardUncrossed is true
            let itemsToUpdate = discardUncrossed
                ? inCart + shoppingList
                : inCart

            // Batch update items to SUGGESTION status
            for item in itemsToUpdate {
                await updateItemStatus(item, to: .suggestion)
            }

            // Trip-scoped notes ("get only 1", "optional if found") die with the trip
            await clearEphemeralNotes()

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
                "shoppingStoreId": NSNull(),
                "shoppingStartedAt": NSNull()
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let household) = root["updateHousehold"] {
                    // Update local state
                    if case .string(let status) = household["shoppingStatus"] {
                        shoppingStatus = ShoppingStatus(rawValue: status) ?? .idle
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

    /// Force-finish an abandoned shopping session started by another member.
    /// Only allowed once `isSessionAbandoned` is true (session idle > threshold).
    /// Moves any IN_CART items back to ACTIVE — nothing is treated as shopped.
    func forceFinishAbandonedSession() async {
        guard isSessionAbandoned else {
            logger.warning("forceFinishAbandonedSession called but session is not abandoned")
            return
        }
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        let abandonedByName = activeShopperDisplayName ?? "the shopper"
        stopAbandonedCheckTimer()

        // Move IN_CART items back to ACTIVE so nothing is treated as shopped.
        let inCartItems = items.filter { $0.status == .inCart }
        for item in inCartItems {
            await updateItemStatus(item, to: .active)
        }

        do {
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
                "shoppingStoreId": NSNull(),
                "shoppingStartedAt": NSNull()
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

            switch response {
            case .success:
                shoppingStatus = .idle
                activeShopperId = nil
                shoppingStoreId = nil
                shoppingStartedAt = nil
                showToast(message: "Ended abandoned session from \(abandonedByName)", type: .success)
                logger.info("Force-finished abandoned shopping session by \(abandonedByName); returned \(inCartItems.count) in-cart items to list")
            case .failure(let error):
                showToast(message: "Failed to end session", type: .error)
                logger.error("Failed to force-finish shopping: \(error)")
            }
        } catch {
            showToast(message: "Failed to end session", type: .error)
            logger.error("Failed to force-finish shopping: \(error)")
        }
    }

    /// Update an item's status
    private func updateItemStatus(_ item: GroceryItem, to newStatus: GroceryItem.ItemStatus, updateAddedAt: Bool = false) async {
        let now = Date()
        let currentUserId = AmplifyService.shared.currentUser?.userId ?? ""

        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updatedItem = item
            updatedItem.status = newStatus
            updatedItem.version += 1
            if updateAddedAt {
                updatedItem.addedAt = now
            }
            if newStatus == .active {
                updatedItem.addedBy = currentUserId
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
            if newStatus == .active {
                input["addedBy"] = currentUserId
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            _ = try await apiMutate(request)
        } catch {
            logger.error("Failed to update item status: \(error)")
        }
    }

    // MARK: - Ad-Hoc Trip Management

    /// Persist an item's ad-hoc flags, optionally alongside a status change.
    private func setAdHocFlags(
        _ item: GroceryItem,
        adHoc: Bool,
        pulled: Bool,
        status: GroceryItem.ItemStatus? = nil
    ) async {
        // Optimistic update
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            updated.adHoc = adHoc
            updated.adHocPulled = pulled
            if let status { updated.status = status }
            updated.version += 1
            items[index] = updated
            applySorting()
        }

        do {
            var input: [String: Any] = [
                "id": item.id,
                "adHoc": adHoc,
                "adHocPulled": pulled,
                "version": item.version + 1
            ]
            if let status { input["status"] = status.rawValue }

            let document = """
            mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
                updateGroceryItem(input: $input) {
                    id status adHoc adHocPulled version
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            _ = try await apiMutate(request)
        } catch {
            if error is PaperModeActive { return }
            // Revert on failure — a stuck ad-hoc flag would hide the item from both lists
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            }
            logger.error("Failed to update ad-hoc flags: \(error)")
        }
    }

    /// Start a store-less errand. Only allowed from IDLE, so it can never race a store trip.
    func enterAdHocMode() async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }
        guard let currentUserId = AmplifyService.shared.currentUser?.userId else {
            showToast(message: "Not signed in", type: .error)
            return
        }
        guard shoppingStatus == .idle else {
            showToast(message: "Someone is already shopping", type: .warning)
            return
        }

        do {
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let document = """
            mutation UpdateHousehold($input: UpdateHouseholdInput!) {
                updateHousehold(input: $input) {
                    id shoppingStatus activeShopperId shoppingStoreId shoppingStartedAt
                }
            }
            """

            // No store binding — that's the whole point of an errand
            let input: [String: Any] = [
                "id": householdId,
                "shoppingStatus": "AD_HOC",
                "activeShopperId": currentUserId,
                "shoppingStoreId": NSNull(),
                "shoppingStartedAt": iso8601Formatter.string(from: Date())
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

            switch response {
            case .success:
                shoppingStatus = .adHoc
                activeShopperId = currentUserId
                shoppingStoreId = nil
                selectedHouseholdStore = nil
                shoppingStartedAt = Date()
                logger.info("Entered ad-hoc mode")
            case .failure(let error):
                showToast(message: "Couldn't start the errand", type: .error)
                logger.error("Failed to enter ad-hoc mode: \(error)")
            }
        } catch {
            showToast(message: "Couldn't start the errand", type: .error)
            logger.error("Failed to enter ad-hoc mode: \(error)")
        }
    }

    /// Move an item off the main list onto the errand. It keeps ACTIVE status but is
    /// flagged as pulled, so it returns to the main list if the errand ends without it.
    func pullItemToAdHoc(_ item: GroceryItem) async {
        guard isAdHocMode else { return }
        await setAdHocFlags(item, adHoc: true, pulled: true)
        showToast(message: "\(item.name) moved to this trip")
    }

    /// Put a pulled item back on the main list mid-errand, undoing `pullItemToAdHoc`.
    func returnItemToMainList(_ item: GroceryItem) async {
        guard item.adHoc else { return }
        await setAdHocFlags(item, adHoc: false, pulled: false, status: .active)
        showToast(message: "\(item.name) back on the main list")
    }

    /// Finish the errand. Bought items are learned as suggestions; items pulled off the
    /// main list are restored to it; freshly typed leftovers are discarded as one-offs.
    func exitAdHocMode() async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        let bought = adHocInCart
        let leftoverPulled = adHocList.filter { $0.adHocPulled }
        let leftoverFresh = adHocList.filter { !$0.adHocPulled }

        let stats = ShoppingCompletionStats(
            itemsPickedUp: bought.count,
            itemsNotPickedUp: leftoverPulled.count + leftoverFresh.count,
            itemsAddedDuringTrip: 0,
            customItemsLearned: bought.filter { $0.isCustom }.count,
            storeName: "Quick Trip",
            startedAt: shoppingStartedAt ?? Date(),
            endedAt: Date()
        )

        // Bought → learned as a suggestion for next time, and off the errand
        for item in bought {
            await setAdHocFlags(item, adHoc: false, pulled: false, status: .suggestion)
        }

        // Pulled but not found → back onto the main list, exactly where it came from
        for item in leftoverPulled {
            await setAdHocFlags(item, adHoc: false, pulled: false, status: .active)
        }

        // Typed fresh for this errand and not bought → a one-off, discard it
        for item in leftoverFresh {
            await deleteItem(item)
        }

        // Trip-scoped notes die with the trip, same as a store run
        await clearEphemeralNotes()

        do {
            let document = """
            mutation UpdateHousehold($input: UpdateHouseholdInput!) {
                updateHousehold(input: $input) {
                    id shoppingStatus activeShopperId shoppingStoreId
                }
            }
            """

            let input: [String: Any] = [
                "id": householdId,
                "shoppingStatus": "IDLE",
                "activeShopperId": NSNull(),
                "shoppingStoreId": NSNull(),
                "shoppingStartedAt": NSNull()
            ]

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["input": input],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            _ = try await apiMutate(request)
        } catch {
            logger.error("Failed to clear ad-hoc status: \(error)")
        }

        shoppingStatus = .idle
        activeShopperId = nil
        shoppingStoreId = nil
        shoppingStartedAt = nil

        // A trip where nothing was added and nothing bought has no story to tell.
        if bought.isEmpty && leftoverPulled.isEmpty && leftoverFresh.isEmpty {
            logger.info("Cancelled an empty ad-hoc trip")
            return
        }

        shoppingCompletionStats = stats
        showShoppingCompletedSheet = true

        logger.info("Ended ad-hoc trip — \(bought.count) bought, \(leftoverPulled.count) restored, \(leftoverFresh.count) discarded")
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
                    shoppingStartedAt
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: ["id": householdId],
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiQuery(request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let household) = root["getHousehold"] {
                    // Update local state
                    if case .string(let status) = household["shoppingStatus"] {
                        shoppingStatus = ShoppingStatus(rawValue: status) ?? .idle
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

                    // Session start time — needed on non-shopper devices for the
                    // abandoned-session banner.
                    if shoppingStatus != .idle {
                        if case .string(let startedAtString) = household["shoppingStartedAt"] {
                            let formatter = ISO8601DateFormatter()
                            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            shoppingStartedAt = formatter.date(from: startedAtString)
                                ?? ISO8601DateFormatter().date(from: startedAtString)
                                ?? shoppingStartedAt
                        } else if shoppingStartedAt == nil {
                            // Field not written (older app version) — fall back to first observation.
                            shoppingStartedAt = Date()
                        }
                    } else {
                        shoppingStartedAt = nil
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

                        // Restart the inactivity reminder — we lost any prior schedule
                        // when the app was killed.
                        await ShopperReminderService.shared.requestPermissionIfNeeded()
                        bumpShopperActivity()

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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiQuery(request)

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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(graphQLRequest)

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
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await apiMutate(request)

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

        var notesEphemeral = false
        if case .boolean(let value) = obj["notesEphemeral"] { notesEphemeral = value }

        var adHoc = false
        if case .boolean(let value) = obj["adHoc"] { adHoc = value }

        var adHocPulled = false
        if case .boolean(let value) = obj["adHocPulled"] { adHocPulled = value }

        var productId: String? = nil
        if case .string(let value) = obj["productId"] { productId = value }

        var lockedBy: String? = nil
        if case .string(let value) = obj["lockedBy"] { lockedBy = value }

        var version: Int = 0
        if case .number(let value) = obj["version"] { version = Int(value) }

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
            notesEphemeral: notesEphemeral,
            adHoc: adHoc,
            adHocPulled: adHocPulled,
            isCustom: isCustom,
            productId: productId,
            status: status,
            lockedBy: lockedBy,
            addedBy: addedBy,
            addedAt: addedAt,
            version: version,
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
