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
}

@MainActor
class ShoppingListViewModel: ObservableObject {
    // MARK: - Published State
    @Published var items: [GroceryItem] = []
    @Published var isAtStoreMode: Bool = false
    @Published var selectedStore: Store?
    /// One list of stores, owned by StoreService.
    ///
    /// This used to be a second `@Published` array kept in step by hand. It went
    /// out of step: `addAisle` re-based on the service's copy while this screen
    /// read the view model's, so an aisle written from one was invisible to the
    /// other. That produced aisles silently dropped from a layout and mappings
    /// left pointing at ids no longer in it, which surfaced as a raw UUID where
    /// an aisle name belongs.
    var householdStores: [HouseholdStore] {
        get { StoreService.shared.householdStores }
        set { StoreService.shared.householdStores = newValue }
    }
    @Published var selectedHouseholdStore: HouseholdStore?
    @Published var productAisleMappings: [String: [ProductAisleMapping]] = [:] // storeId -> mappings
    /// The item whose detail sheet is open.
    ///
    /// Owned here rather than by `GroceryItemRow` for the same reason as
    /// `itemPendingDeletion` below: the row lives in a List that animates and
    /// rebuilds its rows, and a sheet presented from the row's own `@State`
    /// goes with the row. Saying an aisle out loud writes a mapping, which
    /// republishes the stores, which rebuilds the list — and the sheet you were
    /// standing in vanished mid-edit.
    @Published var itemShowingDetail: GroceryItem?

    /// The item a delete has been asked for, waiting on confirmation.
    ///
    /// Lives here rather than in `GroceryItemRow` because the row is inside a
    /// List that animates and recycles its rows. A confirmation owned by the row
    /// was being presented as the swipe collapsed and the row was rebuilt: the
    /// dialog flashed and its Delete fired without anybody tapping it, which
    /// deleted the item outright. Owned above the list, nothing tears it down
    /// mid-present.
    @Published var itemPendingDeletion: GroceryItem?

    @Published var showToast: Bool = false
    /// A closed gate the list itself hit — the item cap. Shown by whichever
    /// screen is attached with `.allowanceRefusal`.
    @Published var allowanceRefusal: AllowanceRefusal?

    /// Names of changes the server keeps refusing. Non-empty means the list on
    /// this phone has stopped tracking everyone else's, and the person is told
    /// rather than left to work it out.
    @Published var stuckSyncNames: [String] = []

    /// The last thing that went wrong, held until the person dismisses it.
    @Published var activeError: SurfacedError?
    @Published var toastMessage: String = ""
    @Published var toastUserName: String = ""
    @Published var toastType: ToastType = .success
    @Published var isLoading: Bool = false
    /// Kept for compatibility, but no longer the only record of a failure.
    ///
    /// Three code paths wrote to this and **no view in the app ever read it**, so
    /// "your list did not load" was recorded and then discarded. Every writer now
    /// also raises the persistent banner. Do not add a fourth writer without one.
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
    /// Alphabetical, always, and not configurable.
    ///
    /// The question you ask this list twenty times a day is "is milk already on
    /// here?", and alphabetical answers it at a glance while recency makes you
    /// read every row. That beats the argument for keeping insertion order,
    /// which was that recency tells you what was just added — true, but it is
    /// answered better by the toast when it happens, and the ordering cost is
    /// paid on every single lookup.
    ///
    /// Fixed rather than a preference because the value is predictability: a
    /// list whose order you have to think about is one you have to read.
    /// Suggestions keep their control, where hunting through hundreds of rows is
    /// the whole job. And while shopping, At Store overrides all of this with
    /// aisle order anyway.
    var shoppingList: [GroceryItem] {
        items.filter { $0.status == .active }.sorted(by: Self.alphabetical)
    }

    /// Ties broken on id: two items can share a name, and `addedAt` has only
    /// one-second precision — without a tiebreak they follow the backend's
    /// unordered scan and reshuffle on every refresh.
    static func alphabetical(_ a: GroceryItem, _ b: GroceryItem) -> Bool {
        let c = a.name.localizedCaseInsensitiveCompare(b.name)
        return c == .orderedSame ? a.id < b.id : c == .orderedAscending
    }

    static func newestFirst(_ a: GroceryItem, _ b: GroceryItem) -> Bool {
        if a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
        return a.id < b.id
    }

    /// Everything the household holds — list, cart and suggestions — which is
    /// what the item allowance counts. One pool with a status, not two lists.
    var totalItemCount: Int { items.count }

    /// Items already in the cart during the current shopping trip
    /// Same order as the list it came from, so an item does not jump position
    /// when you tick it off.
    var inCart: [GroceryItem] {
        items.filter { $0.status == .inCart }.sorted(by: Self.alphabetical)
    }

    /// Suggested items from previous shopping trips
    /// Sorted by whatever the user picked, because this is the list with two
    /// hundred rows in it.
    var suggestions: [GroceryItem] {
        let all = items.filter { $0.status == .suggestion }
        switch currentSort {
        case .recentFirst:
            return all.sorted(by: Self.newestFirst)
        case .aToZ:
            return all.sorted {
                let c = $0.name.localizedCaseInsensitiveCompare($1.name)
                return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
            }
        case .zToA:
            return all.sorted {
                let c = $0.name.localizedCaseInsensitiveCompare($1.name)
                return c == .orderedSame ? $0.id < $1.id : c == .orderedDescending
            }
        }
    }

    // MARK: - Ad-Hoc Trip

    /// True while another member holds an active session of any kind, so this
    /// device must not mutate the list. Two people editing while one of them is
    /// standing in an aisle produces races nobody can reason about — and for a
    /// two-person household, "text them" is a better channel than a live edit.
    var isListLockedByOtherSession: Bool {
        isSomeoneElseShopping
    }

    /// The single response to "you tried to change the list while someone else is
    /// out". Every mutation path says exactly this, so it lives in one place —
    /// there used to be two answers (a toast for most actions, a request/approve
    /// inbox for adds) and the inbox was never once used.
    func warnListReadOnly() {
        // Names the person, because "while shopping" reads as a rule rather than
        // a situation with an end and someone you could text.
        let who = activeShopperDisplayName.map { "\($0) is" } ?? "Someone's"
        showToast(message: "\(who) shopping — the list is locked until they finish", type: .warning)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
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

    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    private var subscriptionCancellables = Set<AnyCancellable>()
    private var householdChangedObserver: NSObjectProtocol?
    private var pendingOptimisticIds: Set<String> = []
    private var pendingRemovals: Set<String> = []
    private var hasLoadedInitialData = false

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

        // Restore the rest of the trip, not just the list. Without these, opening
        // the app cold in a car park meant no store to choose and no aisle order,
        // which is most of what At Store is for.
        if let stores = snapshot.stores, !stores.isEmpty, householdStores.isEmpty {
            householdStores = stores
            // Flag it, because loadStores skips fetching when householdStores is
            // already populated — and restoring from the snapshot populates it.
            // Without this the app would come up on cached stores and never
            // refresh them, which silently disabled the department backfill.
            storesAreFromSnapshot = true
        }
        if let mappings = snapshot.aisleMappings, !mappings.isEmpty {
            for (storeId, list) in mappings where productAisleMappings[storeId] == nil {
                productAisleMappings[storeId] = list
            }
        }

        logger.info("Restored \(snapshot.items.count) items, \(snapshot.stores?.count ?? 0) stores, \(snapshot.aisleMappings?.count ?? 0) mapped stores from local snapshot")
    }

    /// Called whenever stores or aisle mappings change, so the offline copy keeps
    /// up. Separate from the item stream because these change rarely and are
    /// large; folding them into the 600ms item debounce would rewrite them on
    /// every tick of a shopping trip.
    private func persistShoppingContext() {
        LocalListStore.save(
            items: items,
            householdId: householdId,
            stores: householdStores,
            aisleMappings: productAisleMappings
        )
    }

    private func setupLocalSnapshotSaving() {
        // Debounced so a burst of edits writes once, not once per keystroke.
        $items
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] items in
                LocalListStore.save(items: items, householdId: self?.householdId)
            }
            .store(in: &cancellables)

        // Stores and mappings change rarely, so a longer debounce and their own
        // stream. Both are needed to shop offline.
        Publishers.CombineLatest(StoreService.shared.$householdStores, $productAisleMappings)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.persistShoppingContext()
            }
            .store(in: &cancellables)
    }

    deinit {
        if let observer = householdChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

    /// Every network call in this view model goes through these two wrappers.
    private func apiMutate(_ request: GraphQLRequest<JSONValue>) async throws -> GraphQLResponse<JSONValue> {
        return try await Amplify.API.mutate(request: request)
    }

    /// Every read goes through here, and it retries.
    ///
    /// It used to be a single attempt. That is the wrong shape for a phone: iOS
    /// tears down sockets while the app is suspended, so the first request after
    /// coming back from the background very often fails on a connection that is
    /// perfectly healthy. With one attempt, that blip travelled all the way up to
    /// "the server is unreachable" — while the user sat on working wifi.
    ///
    /// Retrying here rather than at the call sites means every caller gets it,
    /// and the layers above only ever see failures that survived three attempts.
    private func apiQuery(_ request: GraphQLRequest<JSONValue>) async throws -> GraphQLResponse<JSONValue> {
        let delays: [UInt64] = [400_000_000, 1_200_000_000]  // 0.4s, then 1.2s
        var lastError: Error?

        for attempt in 0...delays.count {
            do {
                return try await Amplify.API.query(request: request)
            } catch {
                // A bad token will fail identically forever. Retrying it wastes
                // the user's time and delays the sign-out they actually need.
                if AmplifyService.shared.isAuthError(error) { throw error }

                lastError = error
                if attempt < delays.count {
                    logger.info("apiQuery attempt \(attempt + 1) failed, retrying")
                    try? await Task.sleep(nanoseconds: delays[attempt])
                }
            }
        }

        logger.error("apiQuery failed after \(delays.count + 1) attempts")
        throw lastError ?? URLError(.cannotConnectToHost)
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
            // Reached after a two-second wait loop, and it used to end here in
            // silence — an empty list that looked like an empty list, not like a
            // failure to find out which household you are in.
            logger.error("loadShoppingList: No household ID available")
            showToast(message: "Couldn't work out which household this is. Close the app and open it again.",
                      type: .error)
            return
        }

        isLoading = true
        defer { isLoading = false; hasLoadedInitialData = true }

        do {
            // Query the householdId GSI, not listGroceryItems with a filter. The old
            // comment here claimed `status` was a required argument; the deployed
            // schema says otherwise — only `householdId: ID!` is required, and
            // `status` is an optional sort-key condition. Filtering instead of
            // querying made this a full table Scan: DynamoDB read every item of
            // every household on every list load and discarded the non-matches.
            //
            // It was also silently lossy. On a Scan, `limit` caps rows EXAMINED,
            // not rows returned, so once the table passed 1000 rows a household
            // could lose items off the end of its own list. Paginating on the GSI
            // fixes both — each page is 1000 items of this household only.
            let document = """
            query ListItemsByHousehold($householdId: ID!, $limit: Int, $nextToken: String) {
                listItemsByHouseholdAndStatus(householdId: $householdId, limit: $limit, nextToken: $nextToken) {
                    items {
                        id
                        householdId
                        name
                        normalizedName
                        quantity
                        notes
                        notesEphemeral
                        isCustom
                        productId
                        status
                        lockedBy
                        addedBy
                        addedAt
                        version
                        images
                    }
                    nextToken
                }
            }
            """

            var fetched: [GroceryItem] = []
            var nextToken: String? = nil
            var parseFailed = false
            var loadFailed = false

            repeat {
                var variables: [String: Any] = ["householdId": householdId, "limit": 1000]
                if let nextToken { variables["nextToken"] = nextToken }

                let request = GraphQLRequest<JSONValue>(
                    document: document,
                    variables: variables,
                    responseType: JSONValue.self,
                    authMode: AWSAuthorizationType.amazonCognitoUserPools
                )

                let response = try await apiQuery(request)

                switch response {
                case .success(let json):
                    guard case .object(let root) = json,
                          case .object(let listResult) = root["listItemsByHouseholdAndStatus"],
                          case .array(let itemsJson) = listResult["items"] else {
                        logger.error("Failed to parse items response structure")
                        parseFailed = true
                        break
                    }
                    fetched.append(contentsOf: itemsJson.compactMap { parseGroceryItem($0) })
                    if case .string(let token) = listResult["nextToken"] {
                        nextToken = token
                    } else {
                        nextToken = nil
                    }
                case .failure(let error):
                    logger.error("Failed to fetch items: \(String(describing: error))")
                    self.errorMessage = error.localizedDescription
                    showToast(message: "Couldn't load your list. Pull down to try again.", type: .error)
                    if AmplifyService.shared.isAuthError(error) {
                        try? await AmplifyService.shared.signOut()
                        return
                    }
                    handleServerUnreachable()
                    // Stop paging and leave `items` alone rather than publishing
                    // a half-fetched list, which would look like someone deleted
                    // the rest of it. Deliberately a flag and not a `return` —
                    // returning here would skip the tail of this function, and
                    // the tail is where subscriptions get re-established. One
                    // failed load would silently kill realtime sync for the rest
                    // of the session.
                    loadFailed = true
                    nextToken = nil
                }
            } while nextToken != nil && !parseFailed && !loadFailed

            // Two states, and no cleverness between them.
            //
            // Work still queued and still plausibly sendable: hold the local copy,
            // because publishing the server's older list here is what would throw
            // away everything crossed off in a dead zone. That is the whole reason
            // the outbox exists.
            //
            // Work the server has refused repeatedly: the queue is not going to
            // drain, so holding the list back is no longer protecting anything —
            // it is freezing this phone against the rest of the household, which
            // it did to a real list for a day and a half. `flushOutbox` fills in
            // `stuckSyncNames`, the person is told what cannot be saved, and they
            // decide. The server is the golden source and nothing is merged.
            // A flag, never a `return` — the comment on `loadFailed` above says why
            // and this path ignored it. Returning here skips the tail of the
            // function, and the tail is where `setupSubscriptions()` runs, so
            // holding the list for one queued change also killed realtime sync
            // for the rest of the session. That is how a phone stops seeing what
            // anyone else adds and never recovers on its own.
            let holdingForOutbox = !Outbox.shared.isEmpty
            if holdingForOutbox {
                logger.info("Holding local list — \(Outbox.shared.count) change(s) still pending")
                noteServerReachable()
            }

            if !parseFailed && !loadFailed && !holdingForOutbox {
                self.items = fetched
                applySorting()
                isShowingLocalSnapshot = false
                noteServerReachable()

                logger.info("Loaded \(self.items.count) items: \(self.shoppingList.count) active, \(self.inCart.count) in cart, \(self.suggestions.count) suggestions")
            }

        } catch {
            logger.error("Error loading shopping list: \(error)")
            errorMessage = error.localizedDescription
            showToast(message: "Couldn't load your list. Pull down to try again.", type: .error)
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

        // Are we still in this household at all?
        //
        // Removal is a Lambda writing straight to DynamoDB, so no AppSync
        // mutation fires and no subscription can carry the news — and the
        // token keeps its group claim for up to fifteen minutes, so queries
        // go on succeeding too. Nothing pushes this; it has to be asked.
        // Pull-to-refresh and returning to the app both come through here.
        if case .some(.none) = await AmplifyService.shared.refreshHouseholdMembership() {
            handleRemovedFromHousehold()
            return
        }

        // Parallel fetch
        async let itemsTask: () = loadShoppingList(forceRefresh: true)
        async let storesTask: () = loadStores(forceRefresh: true)

        _ = await (itemsTask, storesTask)

        // Who is shopping, and whether anybody still is.
        //
        // This was missing, and the symptom is nasty because everything else on
        // screen looks right: the items refresh, the cart empties, and the
        // "someone is shopping" banner stays up. Observed after the other member
        // had finished twice. Status only arrives by subscription or on launch,
        // so a dropped subscription left it wrong until the app was restarted —
        // and pull-to-refresh, the obvious thing to try, went through here and
        // did not touch it.
        _ = await fetchHouseholdShoppingStatus()

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
        // List is read-only for remote members during active shopping, exactly as
        // it already was for moving to cart, locking and editing notes.
        //
        // This used to route to a request/approve inbox. That was removed: in
        // seven months of use it was never invoked once, and the premise was
        // wrong. An in-app request has no delivery guarantee, so anything actually
        // urgent gets sent again by text anyway — and then you have asked twice
        // and still don't know if they saw it.
        if isListLockedByOtherSession {
            warnListReadOnly()
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

        // The item allowance, checked here and only here. Items are written
        // straight to the table, so this is the one cap the server cannot
        // refuse; a device that is offline can pass it and sync later, which was
        // accepted — see MONETIZATION.qmd. Checked after the sign-in guards and
        // before the duplicate checks, because re-adding something already on
        // the list or in suggestions does not create an item.
        if let allowance = AllowanceService.shared.summary,
           !allowance.entitled,
           totalItemCount >= allowance.itemsCap,
           !items.contains(where: { $0.normalizedName == normalizeName(name) }) {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            allowanceRefusal = AllowanceRefusal(kind: .items)
            return
        }

        // Check for duplicates in cached list (exact normalized-name match only —
        // fuzzy token-subset matching is deliberately restricted to the bulk-import
        // review picker, where the user gets to accept/reject each candidate. Silent
        // auto-merge risks buying the wrong thing, e.g. "coconut milk" collapsing
        // into "coconut milk yogurt".)
        let normalizedName = normalizeName(name)
        let listToCheck = shoppingList
        let cartToCheck = inCart

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

        // Check suggestions - reactivate existing item instead of creating duplicate
        if let suggestionItem = suggestions.first(where: { $0.normalizedName == normalizedName }) {
            await restoreItem(suggestionItem)
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
                    id householdId name normalizedName quantity notes notesEphemeral isCustom productId
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
            pendingOptimisticIds.remove(itemId)
            // Deleting what the user just typed because we could not reach a
            // server would be the worst bug in the app. Offline it stays and is
            // queued; only a genuine rejection removes it.
            let queued = await queueOrRevert(itemId: itemId, kind: .create, error: error,
                                             failureMessage: "Failed to add item")
            if !queued {
                items.removeAll { $0.id == itemId }
            }
            print("Add item error: \(error)")
        }
    }

    // MARK: - Move Item to Cart
    func moveToCart(_ item: GroceryItem) async {
        // List is read-only for remote members during active shopping
        if isListLockedByOtherSession {
            warnListReadOnly()
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full
        // control, and likewise for the runner of a store-less errand)
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

        // She crossed something off. That is the activity the reminder is about,
        // whether or not the write reaches the server.
        bumpShopperActivity()

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
                    id householdId name normalizedName quantity notes notesEphemeral isCustom productId
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
            case .success:
                break
            case .failure(let error):
                await queueOrRevert(itemId: item.id, kind: .update, error: error,
                                    failureMessage: "Failed to add item to cart")
            }
        } catch {
            await queueOrRevert(itemId: item.id, kind: .update, error: error,
                                failureMessage: "Failed to add item to cart")
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
                break
            case .failure(let error):
                logger.error("Move to suggestion failed: \(error)")
                await loadShoppingList()
                showToast(message: "Failed to move item", type: .error)
            }
        } catch {
            await queueOrRevert(itemId: item.id, kind: .update, error: error,
                                failureMessage: "Failed to move item")
            print("Move to suggestion error: \(error)")
        }
    }

    // MARK: - Restore Item
    // MARK: - Restore a finished trip

    /// Put the last trip's list back the way it was.
    ///
    /// Finishing a trip sweeps everything into suggestions, which is right most
    /// of the time and wrong the once — the trip that got cut short, or the one
    /// you finished at the wrong store. The names are already on this phone, so
    /// rebuilding costs nothing but a tap.
    ///
    /// Items are matched against existing suggestions by normalised name and
    /// flipped back to active. Only a name with no match at all is created, so
    /// restoring twice does not leave two cartons of milk on the list.
    ///
    /// Returns how many items ended up back on the list.
    @discardableResult
    func restoreLastTrip() async -> Int {
        if isListLockedByOtherSession {
            warnListReadOnly()
            return 0
        }

        guard let trip = TripStats.shared.restorableTrip else { return 0 }

        // Counted from the list itself, before and after, rather than from the
        // number of times round the loop. `addItem` and `restoreItem` both return
        // nothing and can decline — an allowance refusal, a rejected write, no
        // signal — so incrementing per iteration reported "Put 38 items back"
        // for a restore that had added none of them. The list is the only honest
        // source for what actually landed.
        let before = Set(shoppingList.map(\.id))
        var attempted = 0

        for name in trip.everythingOnTheList {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            // Already on the list — nothing to do, and nothing to duplicate.
            if shoppingList.contains(where: { $0.normalizedName == key })
                || inCart.contains(where: { $0.normalizedName == key }) {
                continue
            }

            attempted += 1
            if let suggestion = suggestions.first(where: { $0.normalizedName == key }) {
                await restoreItem(suggestion)
            } else {
                await addItem(name: name)
            }

            // `addItem` refuses when the list is at its cap, and it refuses by
            // setting this rather than throwing. Without the check, a restore of
            // 38 items ran 38 refusals, added nothing, and then reported a
            // network problem — which is what a real user saw, on Wi-Fi, and
            // reasonably called an incorrect error.
            if allowanceRefusal != nil { break }
        }

        let restored = shoppingList.filter { !before.contains($0.id) }.count

        if attempted == 0 {
            showToast(message: "Everything from that trip is already on the list", type: .info)
        } else if allowanceRefusal != nil {
            // The refusal card is already on screen and says the list is full.
            // Saying it twice, in two different words, is worse than saying it
            // once — and blaming the network for it is worse still.
            logger.info("Restore stopped at the item cap after \(restored) of \(attempted)")
        } else if restored == 0 {
            // Asked for work, got none, and it was not the cap. Silence here is
            // what made a broken restore look like a button that does nothing.
            showToast(message: "Couldn't put anything back. Check your signal and try again.",
                      type: .error)
        } else if restored < attempted {
            showToast(message: "Put \(restored) of \(attempted) items back — the rest didn't save",
                      type: .warning)
        } else {
            showToast(message: restored == 1
                      ? "Put 1 item back on the list"
                      : "Put \(restored) items back on the list",
                      type: .success)
        }

        return restored
    }

    func restoreItem(_ item: GroceryItem) async {
        // Same rule as addItem — read-only while someone else is out.
        if isListLockedByOtherSession {
            warnListReadOnly()
            return
        }

        // On an errand, a suggestion joins the errand rather than the main list.
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
                    id householdId name normalizedName quantity notes notesEphemeral isCustom productId
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
                break
            case .failure(let error):
                await queueOrRevert(itemId: item.id, kind: .update, error: error,
                                    failureMessage: "Failed to restore item")
                print("Restore error: \(error)")
            }
        } catch {
            await queueOrRevert(itemId: item.id, kind: .update, error: error,
                                failureMessage: "Failed to restore item")
            print("Restore error: \(error)")
        }
    }

    // MARK: - Delete Item
    func deleteItem(_ item: GroceryItem) async {
        // Same read-only rule as the rest of the list while someone else is out.
        if isListLockedByOtherSession {
            warnListReadOnly()
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full
        // control, and likewise for the runner of a store-less errand)
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
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await apiMutate(request)

            switch response {
            case .success:
                showToast(message: "Deleted \(item.name)")
            case .failure(let error):
                await queueOrRevert(itemId: item.id, kind: .delete, error: error,
                                    failureMessage: "Failed to delete item")
                print("Delete error: \(error)")
            }
        } catch {
            await queueOrRevert(itemId: item.id, kind: .delete, error: error,
                                failureMessage: "Failed to delete item")
            print("Delete error: \(error)")
        }
    }

    // MARK: - Clear all suggestions

    /// Delete every suggestion the household has accumulated.
    ///
    /// Suggestions grow forever by design — everything bought becomes one, and
    /// scrolling past them is how you remember what you need. The cost is that a
    /// few hundred bad ones, from a mis-parsed import or an early experiment, can
    /// only be removed one swipe at a time. This is the way out.
    ///
    /// Household-wide and permanent. Suggestions live on the server, so this is
    /// not "clear my copy" — it empties the list for everyone, and there is no
    /// undo. The caller is responsible for making sure the user knows both.
    ///
    /// Deletes are issued one at a time and failures are counted rather than
    /// thrown: a partial result is normal on a bad connection, and stopping at
    /// the first failure would leave the user with most of their rubbish still
    /// there and no idea how far it got.
    ///
    /// Returns how many were actually removed.
    @discardableResult
    func deleteAllSuggestions(progress: @escaping (Int, Int) -> Void = { _, _ in }) async -> Int {
        if isListLockedByOtherSession {
            warnListReadOnly()
            return 0
        }

        let doomed = suggestions
        guard !doomed.isEmpty else { return 0 }

        var deleted = 0
        for (index, item) in doomed.enumerated() {
            progress(index, doomed.count)
            if await deleteSuggestionRow(item) {
                deleted += 1
                items.removeAll { $0.id == item.id }
            }
        }
        progress(doomed.count, doomed.count)

        if deleted == doomed.count {
            showToast(message: deleted == 1
                      ? "Cleared 1 suggestion"
                      : "Cleared \(deleted) suggestions", type: .success)
        } else {
            // Saying "done" after removing 180 of 235 would be a lie the user
            // discovers by scrolling.
            showToast(message: "Cleared \(deleted) of \(doomed.count) — try again for the rest",
                      type: .warning)
        }

        return deleted
    }

    /// One delete, reported rather than thrown, and deliberately not queued to
    /// the outbox — a bulk wipe attempted offline should fail visibly now, not
    /// replay hundreds of deletes at some later moment the user has forgotten about.
    private func deleteSuggestionRow(_ item: GroceryItem) async -> Bool {
        let document = """
        mutation DeleteGroceryItem($input: DeleteGroceryItemInput!) {
            deleteGroceryItem(input: $input) {
                id
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": ["id": item.id]],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        do {
            switch try await apiMutate(request) {
            case .success:  return true
            case .failure(let error):
                logger.error("Failed to delete suggestion \(item.name): \(error)")
                return false
            }
        } catch {
            logger.error("Failed to delete suggestion \(item.name): \(error)")
            return false
        }
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
                if await !queueOrRevert(itemId: item.id, kind: .update, error: error,
                                        failureMessage: "Failed to update notes"),
                   let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index] = item
                }
                logger.error("Update notes failed: \(error)")
            }
        } catch {
            // On paper the local edit stands — it's the whole point of the mode.
            if await !queueOrRevert(itemId: item.id, kind: .update, error: error,
                                    failureMessage: "Failed to update notes"),
               let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            }
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
            warnListReadOnly()
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
                    id householdId name normalizedName quantity notes notesEphemeral isCustom productId
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
            warnListReadOnly()
            return
        }

        // Check if locked by another user (skip during shopping mode - shopper has full
        // control, and likewise for the runner of a store-less errand)
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
                    id householdId name normalizedName quantity notes notesEphemeral isCustom productId
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

    /// Kept so the many call sites after a fetch still compile and still animate,
    /// but it no longer reorders `items` — `shoppingList`, `inCart` and
    /// `suggestions` each impose their own order now, so reordering the backing
    /// array did nothing except fight them.
    func applySorting(animate: Bool = false) {
        guard animate else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            objectWillChange.send()
        }
    }

    private func legacyApplySorting(animate: Bool = false) {
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

    /// Alphabetical, with `id` breaking ties. Despite the name this does not
    /// consult aisles — the At Store view groups by aisle itself, from the
    /// mappings, so this only needs to give a stable order within a group.
    ///
    /// The tiebreaker is not cosmetic: Swift's sort is not stable, and the app
    /// permits duplicate names (two "Milk" rows with different notes), so
    /// without it those rows swap places on every refetch — the same reshuffle
    /// bug applySorting was fixed for, on the screen where it matters most.
    func sortByAisle() {
        items.sort {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.id < $1.id
        }
    }

    // MARK: - Subscriptions

    func setupSubscriptions() {
        // A GraphQL socket retrying its handshake forever is exactly the hang
        // paper mode exists to prevent, so don't open one.
        guard let householdId = householdId else { return }

        // Clear any existing cancellables to avoid duplicate handlers
        subscriptionCancellables.removeAll()

        SubscriptionService.shared.subscribeToHousehold(householdId)

        // `connectionState` and `lastError` were published and read by nothing.
        // When the sockets drop, this phone stops hearing anything the rest of
        // the household adds — which looks exactly like a household that has
        // stopped adding. Said once per drop, not per retry, and worded as the
        // thing the person can do about it.
        SubscriptionService.shared.$connectionState
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .disconnected where !self.isOffline:
                    self.showToast(message: "Live updates stopped. Pull down to refresh and see anyone else's changes.",
                                   type: .warning)
                case .connected:
                    // Recovered; clear the warning rather than leave it standing.
                    if self.activeError?.isWarning == true { self.activeError = nil }
                default:
                    break
                }
            }
            .store(in: &subscriptionCancellables)

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

        logger.info("Subscriptions set up for household: \(householdId)")
    }

    /// The owner removed us, or the household went away.
    ///
    /// Drops to the no-household state rather than leaving somebody reading and
    /// editing a list they are no longer part of. Writes would still be
    /// accepted for a few minutes — the token outlives the claim — so this is
    /// about not misleading people, not about stopping them.
    func handleRemovedFromHousehold() {
        logger.info("Removed from household — clearing local state")
        teardownSubscriptions()
        items = []
        householdStores = []
        shoppingStatus = .idle
        AmplifyService.shared.currentHouseholdId = nil
        errorMessage = "You're no longer in this household."
        showToast(message: "You're no longer in this household.", type: .error)
        NotificationCenter.default.post(name: .householdChanged, object: nil)
    }

    func teardownSubscriptions() {
        subscriptionCancellables.removeAll()
        SubscriptionService.shared.unsubscribeAll()
        logger.info("Subscriptions torn down")
    }

    // MARK: - Server Unreachable

    /// True when requests are failing and we are showing the local copy. A
    /// condition, not a mode: everything still works, it just isn't syncing.
    @Published private(set) var isOffline = false
    /// True while quietly retrying in the background.
    @Published private(set) var isRetryingConnection = false

    private var consecutiveLoadFailures = 0
    private var reconnectTask: Task<Void, Never>?

    /// The crash-at-the-store case: we came up, couldn't reach anything, but the
    /// local snapshot means there IS a list to shop from. Offer it rather than
    /// leaving the user staring at an empty screen.
    /// Decide whether this failure means "you have no network" or just "that
    /// request didn't work".
    ///
    /// The old version could not tell the difference: one failed request, from
    /// any cause, put the paper-list prompt on screen. Since the request layer
    /// had no retry and iOS kills sockets during suspension, the most common
    /// trigger in practice was simply opening the app after a while — on a
    /// working connection.
    ///
    /// Two signals now have to agree before we say anything:
    ///   - the failure survived apiQuery's three attempts, and
    ///   - either the device has no usable network interface, or a second
    ///     independent load has also failed.
    ///
    /// Offering paper mode is a big, disruptive claim about the user's world.
    /// Be sure before making it; staying quiet costs nothing, because the list
    /// on screen is still there either way.
    private func handleServerUnreachable() {
        consecutiveLoadFailures += 1

        // No interface at all — airplane mode, no bars, wifi off. Nothing is
        // ambiguous about this, so don't make them fail twice to hear it.
        let networkIsPlainlyGone = !NetworkStatus.shared.pathIsSatisfied

        guard networkIsPlainlyGone || consecutiveLoadFailures >= 2 else {
            logger.info("Load failed but the network looks fine — staying quiet")
            return
        }

        guard !isOffline else { return }
        isOffline = true
        logger.info("Going offline — showing the local copy")
        keepTryingToReconnect()
    }

    /// Called whenever a load actually lands. Clears the failure count and
    /// re-arms the prompt, so it is once per *outage* rather than once per
    /// launch — the old flag spent its single shot on the wake-up blip and then
    /// stayed silent through a genuine outage for the rest of the session.
    private func noteServerReachable() {
        consecutiveLoadFailures = 0
        if isOffline {
            isOffline = false
            showToast(message: "Back online", type: .success)
        }
    }

    /// User said no to paper. Keep trying — store wifi often shows up a minute
    /// later, and they shouldn't have to think about it again.
    func keepTryingToReconnect() {
        guard reconnectTask == nil else { return }
        isRetryingConnection = true

        reconnectTask = Task { @MainActor in
            while !Task.isCancelled && isRetryingConnection {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }

                // Push what we did offline before pulling anything down.
                let flushed = await flushOutbox()
                guard flushed else { continue }

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

    // MARK: - Outbox

    /// A mutation failed. Decide whether the local change survives.
    ///
    /// The old behaviour was always to call `loadShoppingList()`, which refetches
    /// and reverts. That is right when the server rejected the change, and wrong
    /// when the server was simply unreachable — it threw away the cross-off you
    /// just made in a dead zone and told you it had failed.
    ///
    /// Returns true if the change was kept and queued.
    @discardableResult
    private func queueOrRevert(
        itemId: String,
        kind: Outbox.Kind,
        error: Error,
        failureMessage: String
    ) async -> Bool {
        let looksOffline = !NetworkStatus.shared.pathIsSatisfied || isOffline

        guard looksOffline else {
            // The server was reachable and said no. Reverting is correct.
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            await loadShoppingList()
            showToast(message: failureMessage, type: .error)
            print("[OUTBOX] not queuing — server reachable, rejected: \(String(describing: error))")
            return false
        }

        Outbox.shared.enqueue(itemId, kind)
        if !isOffline {
            isOffline = true
            keepTryingToReconnect()
        }
        print("[OUTBOX] queued \(kind.rawValue) for \(itemId) (\(Outbox.shared.count) pending)")
        return true
    }


    /// Push everything queued while offline, then refetch.
    ///
    /// Order matters and is the whole point: creates first so later updates have
    /// something to land on, then updates, then deletes. The refetch only runs if
    /// the queue drained — refetching with work still pending would overwrite it,
    /// which is exactly the bug this exists to fix.
    func flushOutbox() async -> Bool {
        guard !Outbox.shared.isEmpty else { return true }

        let queued = Outbox.shared.entries
        print("[OUTBOX] flushing \(queued.count) change(s)")

        let order: [Outbox.Kind] = [.create, .update, .delete]
        var allSucceeded = true

        for kind in order {
            for entry in queued where entry.kind == kind {
                let ok: Bool
                switch kind {
                case .create: ok = await pushCreate(entry.id)
                case .update: ok = await pushUpdate(entry.id)
                case .delete: ok = await pushDelete(entry.id)
                }
                if ok {
                    Outbox.shared.remove(entry.id)
                } else {
                    allSucceeded = false
                    // Count it, and give up once it is clearly never going to be
                    // accepted. An entry that retries for ever used to freeze the
                    // whole list, because the fetch above refused to publish while
                    // anything was queued.
                    if Outbox.shared.recordFailure(entry.id) {
                        print("[OUTBOX] dropped \(kind.rawValue) for \(entry.id) — the server kept refusing it")
                    } else {
                        print("[OUTBOX] \(kind.rawValue) failed for \(entry.id), keeping it queued")
                    }
                }
            }
        }

        print("[OUTBOX] flush \(allSucceeded ? "complete" : "incomplete — \(Outbox.shared.count) left")")

        // Surface anything the server has now refused more than once. Retrying in
        // silence is what let one bad row freeze a household's list for a day and
        // a half with no way back.
        let stuck = Outbox.shared.stuckEntries
        stuckSyncNames = stuck.map { entry in
            items.first(where: { $0.id == entry.id })?.name ?? "An item you removed"
        }

        return allSucceeded
    }

    /// Throw away what will not save and take the server's copy.
    func discardStuckChangesAndReload() async {
        let dropped = Outbox.shared.count
        Outbox.shared.clear()
        stuckSyncNames = []
        logger.warning("Discarded \(dropped) unsendable change(s) at the user's request; reloading from the server")
        await loadShoppingList(forceRefresh: true)
    }

    /// An item created offline: the server has never seen it, so this is a create
    /// with the id the client already assigned.
    private func pushCreate(_ itemId: String) async -> Bool {
        guard let item = items.first(where: { $0.id == itemId }) else {
            // Created and then deleted while offline, and the queue was collapsed
            // to nothing. Not an error.
            return true
        }
        let document = """
        mutation CreateGroceryItem($input: CreateGroceryItemInput!) {
            createGroceryItem(input: $input) { id version }
        }
        """
        var input: [String: Any] = [
            "id": item.id,
            "householdId": item.householdId,
            "name": item.name,
            "normalizedName": item.normalizedName,
            "status": item.status.rawValue,
            "isCustom": item.isCustom,
            "addedBy": item.addedBy,
            "addedAt": ISO8601DateFormatter().string(from: item.addedAt),
            "version": item.version
        ]
        if let quantity = item.quantity { input["quantity"] = quantity }
        if let notes = item.notes { input["notes"] = notes }
        if let productId = item.productId { input["productId"] = productId }
        input["notesEphemeral"] = item.notesEphemeral

        if await runOutboxMutation(document, ["input": input]) { return true }

        // The write may well have landed and only the reply been lost — a
        // timeout on a mutation the server committed. Retrying the create then
        // fails for ever on the duplicate id, which is exactly how a queue gets
        // permanently stuck. If the row is already there, an update succeeds and
        // the entry is done; that is both the repair and the test for it.
        print("[OUTBOX] create rejected for \(itemId), trying update in case the row already exists")
        return await pushUpdate(itemId)
    }

    /// The server has this item; the local copy is newer. Pushes the whole
    /// mutable state rather than a diff, because the outbox records that an item
    /// changed, not how many times.
    private func pushUpdate(_ itemId: String) async -> Bool {
        guard let item = items.first(where: { $0.id == itemId }) else { return true }
        let document = """
        mutation UpdateGroceryItem($input: UpdateGroceryItemInput!) {
            updateGroceryItem(input: $input) { id version }
        }
        """
        var input: [String: Any] = [
            "id": item.id,
            "status": item.status.rawValue,
            "version": item.version,
            "addedBy": item.addedBy,
            "addedAt": ISO8601DateFormatter().string(from: item.addedAt),
            "notesEphemeral": item.notesEphemeral
        ]
        input["notes"] = item.notes ?? ""
        input["quantity"] = item.quantity ?? ""

        return await runOutboxMutation(document, ["input": input])
    }

    private func pushDelete(_ itemId: String) async -> Bool {
        let document = """
        mutation DeleteGroceryItem($input: DeleteGroceryItemInput!) {
            deleteGroceryItem(input: $input) { id }
        }
        """
        return await runOutboxMutation(document, ["input": ["id": itemId]])
    }

    private func runOutboxMutation(_ document: String, _ variables: [String: Any]) async -> Bool {
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )
        do {
            switch try await apiMutate(request) {
            case .success: return true
            case .failure(let error):
                print("[OUTBOX] mutation rejected: \(String(describing: error))")
                return false
            }
        } catch {
            return false
        }
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
            // Repaired rather than reported. A subscription telling us an item
            // changed, followed by a failed fetch of that item, left the row
            // showing the old values for ever — but it is not something the
            // person did, so a banner would be noise. Refetching the list is
            // both quieter and an actual fix.
            print("handleItemUpdated: Could not fetch item \(itemId), refreshing the list instead")
            await loadShoppingList(forceRefresh: true)
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
    func showToast(message: String, userName: String = "", type: ToastType = .success) {
        // On paper, a write never reaching the server is the design, not a fault.
        // Reporting it as an error would tell the user something broke when
        // nothing did — and it would fire on essentially every tap.
        if isOffline && type == .error { return }

        // Errors and warnings do not get three seconds and a fade.
        //
        // A toast that has gone is a message the person never read, and the only
        // way to see it again is to repeat whatever failed — which is the last
        // thing anyone should be encouraged to do after a failure. These stay on
        // screen until they are dismissed. Successes still fade, because nobody
        // needs to acknowledge that something worked.
        if type == .error || type == .warning {
            print("error surfaced: '\(message)'")
            activeError = SurfacedError(message: message, isWarning: type == .warning)
            UINotificationFeedbackGenerator().notificationOccurred(type == .error ? .error : .warning)
            return
        }

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
            // The success message used to fire regardless of this, so a shop
            // whose aisle data had failed to load announced itself as selected
            // and then behaved as though it had no layout at all — every item
            // unmapped, and an offer to spend allowance re-mapping things that
            // were already mapped.
            do {
                let mappings = try await StoreService.shared.fetchMappings(storeId: store.id)
                productAisleMappings[store.id] = mappings
                showToast(message: "Selected \(store.name)")
            } catch {
                logger.error("Failed to load mappings for \(store.name): \(error)")
                showToast(message: "Loaded \(store.name), but not its aisles. Items may show as unsorted — try again when you have signal.",
                          type: .warning)
            }
        }
        logger.info("Selected store: \(store.name)")
    }

    /// Create a new store and add it to the household
    @discardableResult
    func createStore(name: String, chain: String?, aisles: [StoreAisle], seedDepartments: Bool = true) async -> HouseholdStore? {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return nil
        }

        do {
            // Create the store
            var store = try await StoreService.shared.createStore(name: name, chain: chain, householdId: householdId, seedDepartments: seedDepartments)

            // Add aisles to the store
            for aisle in aisles {
                store = try await StoreService.shared.addAisle(to: store, number: aisle.number, name: aisle.name)
            }

            // No append here. `householdStores` is StoreService's array now, and
            // createStore has already put the store in it — appending again
            // listed the same store twice.
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
    private var storesAreFromSnapshot = false

    func loadStores(forceRefresh: Bool = false) async {
        // Skip if stores already loaded (prevents redundant fetches on tab switch).
        // Snapshot-restored stores don't count as loaded: they are a cached copy
        // to shop from offline, not a fetch.
        if !householdStores.isEmpty && !forceRefresh && !storesAreFromSnapshot {
            print("[BACKFILL] loadStores SKIPPED — \(self.householdStores.count) already loaded")
            return
        }
        print("[BACKFILL] loadStores FETCHING — have \(self.householdStores.count), forceRefresh=\(forceRefresh), fromSnapshot=\(self.storesAreFromSnapshot)")

        guard let householdId = householdId else {
            logger.error("loadStores: No household ID available")
            return
        }

        do {
            householdStores = try await StoreService.shared.fetchStores(householdId: householdId)
            storesAreFromSnapshot = false
            logger.info("Loaded \(self.householdStores.count) stores for household")

            if householdStores.isEmpty {
                await createDefaultStore()
            }
        } catch {
            print("[BACKFILL] fetchStores THREW: \(String(describing: error))")
            logger.error("Failed to load stores: \(error)")
        }
    }

    /// Every household gets one plain store so "At Store" is never blocked behind
    /// setup. No aisles defined — the map fills itself in as items get assigned
    /// while shopping, rather than being declared up front.
    private func createDefaultStore() async {

        logger.info("No stores for this household — creating the default one")
        _ = await createStore(
            name: StoreService.defaultStoreName,
            chain: nil,
            aisles: []
        )
    }

    /// The stores, with the small shops last.
    ///
    /// A shop with no aisles is the fallback you reach for when you are not at
    /// one of your regular stores, so it belongs at the bottom rather than
    /// sitting above them. Keyed off the layout, so a store somebody strips the
    /// departments from moves down with it. Stable within each group, which
    /// keeps the fetch order everywhere else.
    var storesInPickingOrder: [HouseholdStore] {
        householdStores.enumerated()
            .sorted { a, b in
                let aSmall = a.element.aisleLayout.isEmpty
                let bSmall = b.element.aisleLayout.isEmpty
                return aSmall == bSmall ? a.offset < b.offset : !aSmall
            }
            .map(\.element)
    }



    // MARK: - Reminder Timer Management

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
    ///
    /// Called on session start and on every cross-off the user makes — not on
    /// every one the server confirms. That distinction is the bug it was written
    /// with: the bump lived inside `case .success`, so on a weak signal the
    /// writes failed, the timer was never pushed out, and "Nothing crossed off in
    /// a while" arrived while she was at 14 of 24 items in the shop.
    ///
    /// The reminder exists to ask "have you forgotten to tap Done", which is a
    /// question about the person, not about the network.
    ///
    /// Silent no-op if the current user is not the active shopper.
    func bumpShopperActivity() {
        guard isCurrentUserShopping else { return }
        ShopperReminderService.shared.schedule(after: Self.shopperInactivityReminder)
    }

    // MARK: - Shopping Mode Management

    /// Enter shopping mode at a specific store.
    ///
    /// Local state is set first and the household write is best-effort. It used to
    /// be the other way round: the mutation had to land before anything happened,
    /// so tapping "At Store" in a car park with no signal produced a red toast and
    /// nothing else — the app refused to let you shop the list already in your
    /// hand. The household write only exists so other members see that you are out
    /// and go read-only; if it fails there is no signal, so they were not going to
    /// be told anyway.
    func enterShoppingMode(store: HouseholdStore) async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        guard let currentUserId = AmplifyService.shared.currentUser?.userId else {
            showToast(message: "Not signed in", type: .error)
            return
        }

        // You are shopping the moment you say so.
        shoppingStatus = .atStore
        activeShopperId = currentUserId
        shoppingStoreId = store.id
        selectedHouseholdStore = store
        shoppingStartedAt = Date()
        isAtStoreMode = true

        // Aisle order comes from mappings already on disk, so a cold offline start
        // still walks the store in order for anything mapped before.
        if let cached = productAisleMappings[store.id], !cached.isEmpty {
            logger.info("At-Store: using \(cached.count) cached aisle mappings")
        }

        do {
            // Update Household via GraphQL mutation
            let document = """
            mutation UpdateHousehold($input: UpdateHouseholdInput!) {
                updateHousehold(input: $input) {
                    id
                    # Required, though nothing on screen reads it. Household is
                    # guarded by groupDefinedIn('groupName'), and AppSync decides
                    # whether a subscriber may receive a mutation by evaluating
                    # that rule against the payload the mutation returned. Leave
                    # groupName out and the payload has nothing to authorise
                    # against, so every other member is silently skipped — the
                    # shopper sees At Store because of a local update, and
                    # everybody else sees nothing at all.
                    groupName
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

                    // Drop mappings pointing at aisles this store no longer has,
                    // before working out what still needs inferring. Otherwise a
                    // bad mapping counts as "mapped" and permanently blocks the
                    // item from ever being re-inferred.
                    if let pruned = try? await StoreService.shared.pruneOrphanedMappings(storeId: store.id), pruned > 0 {
                        logger.info("Pruned \(pruned) orphaned mapping(s) for \(store.name)")
                    }

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
                        if store.aisleLayout.isEmpty {
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

                    // Nudge the shopper if nothing gets crossed off for a while.
                    await ShopperReminderService.shared.requestPermissionIfNeeded()
                    bumpShopperActivity()

                    showToast(message: "Shopping at \(store.name)")
                    logger.info("Entered shopping mode at store: \(store.name)")
                }
            case .failure(let error):
                enteredShoppingModeOffline(store: store, error: error)
            }
        } catch {
            enteredShoppingModeOffline(store: store, error: error)
        }
    }

    /// The session is already live locally; this only reports what the household
    /// will not know about it. Deliberately not an error toast — nothing the user
    /// wanted has failed. They are shopping.
    private func enteredShoppingModeOffline(store: HouseholdStore, error: Error) {
        logger.error("Shopping mode started offline at \(store.name): \(error)")
        showToast(message: "Shopping at \(store.name) · offline, others won't see it", type: .warning)
        persistShoppingContext()
    }

    /// Exit shopping mode
    func exitShoppingMode(discardUncrossed: Bool) async {
        guard let householdId = householdId else {
            showToast(message: "No household selected", type: .error)
            return
        }

        do {
            // Stop reminder timer
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
                    # See the note on entering At Store: groupName must be in the
                    # selection set or no other member is told.
                    groupName
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

                    // Set stats and show completion sheet
                    shoppingCompletionStats = stats
                    showShoppingCompletedSheet = true

                    // Same numbers, kept on this phone so the list menu can show
                    // a running tally. Recorded here because this is the only
                    // point where a trip is definitely finished.
                    TripStats.shared.recordTrip(
                        storeName: storeName,
                        itemNames: itemsInCart.map(\.name),
                        leftBehindNames: itemsOnList.map(\.name),
                        customLearned: customItemsInCart.count,
                        startedAt: startTime,
                        endedAt: endTime
                    )

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
                    # See the note on entering At Store: groupName must be in the
                    # selection set or no other member is told.
                    groupName
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
            // Queued, not just logged. This runs for every in-cart item when a
            // trip is finished, and a log line was its entire failure handling —
            // so ending a trip on a weak checkout signal left those items as
            // suggestions on this phone and still IN_CART on the server, while
            // the completion sheet reported them all picked up. The local state
            // has already been changed optimistically above, which is exactly
            // what the outbox exists to push.
            logger.error("Failed to update item status: \(error)")
            await queueOrRevert(
                itemId: item.id,
                kind: .update,
                error: error,
                failureMessage: "Couldn't save \(item.name) — it has been put back"
            )
        }
    }

    /// Fetch current household shopping status and restore state if current user was shopping
    /// Returns true if the current user is the active shopper and UI should show AtStoreModeView
    @discardableResult
    /// Take an in-progress trip over.
    ///
    /// There is one shopper slot and, until now, no way to claim it. If the slot
    /// was held by anybody else — including you on a phone that had lost its
    /// state — the app hid the At Store button because "someone else is
    /// shopping", offered a modal with a single OK, and left you standing in a
    /// shop with no way in and no way to end it. That happened for real.
    func takeOverShopping() async {
        guard let householdId, let me = AmplifyService.shared.currentUser?.userId else { return }

        let document = """
        mutation UpdateHousehold($input: UpdateHouseholdInput!) {
            updateHousehold(input: $input) { id shoppingStatus activeShopperId shoppingStoreId }
        }
        """
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var input: [String: Any] = [
            "id": householdId,
            "shoppingStatus": "AT_STORE",
            "activeShopperId": me,
            "shoppingStartedAt": iso.string(from: shoppingStartedAt ?? Date())
        ]
        // Keep whatever shop the trip was already against; only the shopper moves.
        if let storeId = shoppingStoreId { input["shoppingStoreId"] = storeId }

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        do {
            switch try await apiMutate(request) {
            case .success:
                activeShopperId = me
                shoppingStatus = .atStore
                isAtStoreMode = true
                logger.info("Took over the shopping trip")
            case .failure(let error):
                logger.error("Take over failed: \(String(describing: error))")
                showToast(message: "Couldn't take over — check your signal and try again", type: .error)
            }
        } catch {
            logger.error("Take over threw: \(error)")
            showToast(message: "Couldn't take over — check your signal and try again", type: .error)
        }
    }

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

    // MARK: - Image Management

    /// Upload an image for a grocery item to S3 and update the item record
    func uploadItemImage(for item: GroceryItem, imageData: Data) async throws {
        guard item.images.count < 5 else {
            throw NSError(domain: "ImageError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Maximum 5 images allowed"])
        }

        guard let currentUserId = AmplifyService.shared.currentUser?.userId else {
            throw NSError(domain: "ImageError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not signed in"])
        }

        logger.info("Uploading image, \(imageData.count) bytes")

        // The server picks the key and signs the upload. The client used to
        // build the key itself and write straight to the bucket, which is only
        // safe if the bucket trusts every signed-in account — it did.
        let s3Key = try await ItemImageService.upload(
            data: imageData,
            itemId: item.id,
            householdId: item.householdId
        )
        let imageId = s3Key
            .split(separator: "_").last
            .map { String($0).replacingOccurrences(of: ".jpg", with: "") } ?? UUID().uuidString

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

        // Deleted by the server after it checks the key belongs to this
        // household — not by a signed DELETE handed to the client.
        try await ItemImageService.delete(s3Key: imageToDelete.s3Key)

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

    /// Download an image, via a short-lived signed URL from the server.
    func downloadItemImage(s3Key: String) async throws -> Data {
        try await ItemImageService.download(s3Key: s3Key)
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

}
