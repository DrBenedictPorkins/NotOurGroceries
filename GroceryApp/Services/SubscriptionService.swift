import Foundation
import Combine
import Amplify
import AWSPluginsCore

@MainActor
class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()

    // Published properties for subscription events
    @Published var lastCreatedItem: GroceryItem?
    @Published var lastUpdatedItemId: String?
    @Published var lastDeletedItemId: String?
    @Published var lastHouseholdShoppingUpdate: HouseholdShoppingUpdate?
    @Published var lastShoppingRequest: ShoppingRequest?
    @Published var connectionState: ConnectionState = .disconnected
    @Published var lastError: SubscriptionError?

    struct HouseholdShoppingUpdate {
        let householdId: String
        let shoppingStatus: String?
        let activeShopperId: String?
        let shoppingStoreId: String?
        let shoppingStartedAt: Date?
    }

    struct SubscriptionError: Identifiable {
        let id = UUID()
        let type: ErrorType
        let message: String
        let timestamp: Date

        enum ErrorType {
            case create, update, delete, connection
        }
    }

    // Subscription tasks
    private var createTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var householdTask: Task<Void, Never>?
    private var shoppingRequestTask: Task<Void, Never>?
    private var currentHouseholdId: String?

    // Event debouncing
    private var pendingEvents: [String: (item: GroceryItem, type: EventType)] = [:]
    private var debounceTask: Task<Void, Never>?

    enum ConnectionState {
        case connecting
        case connected
        case disconnected
        case reconnecting
    }

    enum EventType {
        case created
        case updated
        case deleted
    }

    private init() {}

    // MARK: - Event Debouncing

    private func debounceEvent(_ item: GroceryItem, type: EventType) {
        pendingEvents[item.id] = (item, type)
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            flushEvents()
        }
    }

    private func flushEvents() {
        let eventsToFlush = pendingEvents
        pendingEvents.removeAll()

        for (_, event) in eventsToFlush {
            switch event.type {
            case .created:
                self.lastCreatedItem = event.item
            case .updated:
                // Updates now handled via lastUpdatedItemId (no debouncing needed)
                break
            case .deleted:
                self.lastDeletedItemId = event.item.id
            }
        }
    }

    // MARK: - Subscribe to Household

    func subscribeToHousehold(_ householdId: String) {
        // Already subscribed to this household - do nothing
        if currentHouseholdId == householdId && createTask != nil {
            print("SubscriptionService: Already subscribed to household \(householdId)")
            return
        }

        // Cancel existing subscriptions if household changes
        if currentHouseholdId != householdId {
            unsubscribeAll()
        }

        currentHouseholdId = householdId
        subscribeToCreate(householdId: householdId)
        subscribeToUpdate(householdId: householdId)
        subscribeToDelete(householdId: householdId)
        subscribeToHouseholdUpdate(householdId: householdId)
        subscribeToShoppingRequests(householdId: householdId)

        print("SubscriptionService: Subscribed to household \(householdId)")
    }

    func unsubscribeAll() {
        createTask?.cancel()
        updateTask?.cancel()
        deleteTask?.cancel()
        householdTask?.cancel()
        shoppingRequestTask?.cancel()
        debounceTask?.cancel()
        createTask = nil
        updateTask = nil
        deleteTask = nil
        householdTask = nil
        shoppingRequestTask = nil
        debounceTask = nil
        currentHouseholdId = nil
        connectionState = .disconnected

        print("SubscriptionService: Unsubscribed from all")
    }

    // MARK: - Individual Subscriptions

    private func subscribeToCreate(householdId: String) {
        createTask = Task {
            let document = """
            subscription OnCreateGroceryItem {
                onCreateGroceryItem {
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
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let subscription = Amplify.API.subscribe(request: request)

            do {
                for try await subscriptionEvent in subscription {
                    switch subscriptionEvent {
                    case .connection(let state):
                        print("SubscriptionService: Create connection state: \(state)")
                        updateConnectionState(from: state)
                    case .data(let result):
                        switch result {
                        case .success(let json):
                            if let item = parseGroceryItem(from: json, key: "onCreateGroceryItem"),
                               item.householdId == householdId {
                                // Ensure user is cached for display
                                await ensureUserCached(item.addedBy)
                                debounceEvent(item, type: .created)
                            }
                        case .failure(let error):
                            let errorMessage = parseGraphQLError(error)
                            print("SubscriptionService: Create subscription error - \(errorMessage)")
                            AmplifyService.shared.handleAuthError(error)
                            self.lastError = SubscriptionError(
                                type: .create,
                                message: errorMessage,
                                timestamp: Date()
                            )
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let errorMessage = error.localizedDescription
                    print("SubscriptionService: Create subscription fatal error - \(errorMessage)")
                    AmplifyService.shared.handleAuthError(error)
                    self.lastError = SubscriptionError(
                        type: .create,
                        message: errorMessage,
                        timestamp: Date()
                    )
                }
            }
        }
    }

    private func subscribeToUpdate(householdId: String) {
        updateTask = Task {
            // Only request id - partial updates may not include all fields
            // ViewModel will fetch the full item when notified
            let document = """
            subscription OnUpdateGroceryItem {
                onUpdateGroceryItem {
                    id
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let subscription = Amplify.API.subscribe(request: request)

            do {
                for try await subscriptionEvent in subscription {
                    switch subscriptionEvent {
                    case .connection(let state):
                        print("SubscriptionService: Update connection state: \(state)")
                        updateConnectionState(from: state)
                    case .data(let result):
                        switch result {
                        case .success(let json):
                            // Extract just the ID
                            if case .object(let root) = json,
                               let updateData = root["onUpdateGroceryItem"],
                               case .object(let data) = updateData,
                               case .string(let id) = data["id"] {
                                print("SubscriptionService: Item updated: \(id)")
                                self.lastUpdatedItemId = id
                            }
                        case .failure(let error):
                            let errorMessage = parseGraphQLError(error)
                            print("SubscriptionService: Update subscription error - \(errorMessage)")
                            AmplifyService.shared.handleAuthError(error)
                            self.lastError = SubscriptionError(
                                type: .update,
                                message: errorMessage,
                                timestamp: Date()
                            )
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let errorMessage = error.localizedDescription
                    print("SubscriptionService: Update subscription fatal error - \(errorMessage)")
                    AmplifyService.shared.handleAuthError(error)
                    self.lastError = SubscriptionError(
                        type: .update,
                        message: errorMessage,
                        timestamp: Date()
                    )
                }
            }
        }
    }

    private func subscribeToDelete(householdId: String) {
        deleteTask = Task {
            // Only request id - other fields may be null after deletion
            let document = """
            subscription OnDeleteGroceryItem {
                onDeleteGroceryItem {
                    id
                }
            }
            """

            let request = GraphQLRequest<JSONValue>(
                document: document,
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let subscription = Amplify.API.subscribe(request: request)

            do {
                for try await subscriptionEvent in subscription {
                    switch subscriptionEvent {
                    case .connection(let state):
                        print("SubscriptionService: Delete connection state: \(state)")
                        updateConnectionState(from: state)
                    case .data(let result):
                        switch result {
                        case .success(let json):
                            // Extract just the ID - householdId may be null after deletion
                            if case .object(let root) = json,
                               let deleteData = root["onDeleteGroceryItem"] {
                                // Handle both object and null cases
                                if case .object(let data) = deleteData,
                                   case .string(let id) = data["id"] {
                                    print("SubscriptionService: Item deleted: \(id)")
                                    self.lastDeletedItemId = id
                                }
                            }
                        case .failure(let error):
                            // Log the error with details
                            let errorMessage = parseGraphQLError(error)
                            print("SubscriptionService: Delete subscription error - \(errorMessage)")
                            AmplifyService.shared.handleAuthError(error)
                            self.lastError = SubscriptionError(
                                type: .delete,
                                message: errorMessage,
                                timestamp: Date()
                            )
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let errorMessage = error.localizedDescription
                    print("SubscriptionService: Delete subscription fatal error - \(errorMessage)")
                    AmplifyService.shared.handleAuthError(error)
                    self.lastError = SubscriptionError(
                        type: .delete,
                        message: errorMessage,
                        timestamp: Date()
                    )
                }
            }
        }
    }

    private func subscribeToHouseholdUpdate(householdId: String) {
        householdTask = Task {
            let document = """
            subscription OnUpdateHousehold($id: ID!) {
                onUpdateHousehold(filter: { id: { eq: $id } }) {
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

            let subscription = Amplify.API.subscribe(request: request)

            do {
                for try await subscriptionEvent in subscription {
                    switch subscriptionEvent {
                    case .connection(let state):
                        print("SubscriptionService: Household connection state: \(state)")
                        updateConnectionState(from: state)
                    case .data(let result):
                        switch result {
                        case .success(let json):
                            if case .object(let root) = json,
                               let updateData = root["onUpdateHousehold"],
                               case .object(let data) = updateData,
                               case .string(let id) = data["id"] {

                                // Extract shopping status fields
                                var shoppingStatus: String? = nil
                                if case .string(let value) = data["shoppingStatus"] {
                                    shoppingStatus = value
                                }

                                var activeShopperId: String? = nil
                                if case .string(let value) = data["activeShopperId"] {
                                    activeShopperId = value
                                }

                                var shoppingStoreId: String? = nil
                                if case .string(let value) = data["shoppingStoreId"] {
                                    shoppingStoreId = value
                                }

                                var shoppingStartedAt: Date? = nil
                                if case .string(let value) = data["shoppingStartedAt"] {
                                    let formatter = ISO8601DateFormatter()
                                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                                    shoppingStartedAt = formatter.date(from: value)
                                        ?? ISO8601DateFormatter().date(from: value)
                                }

                                print("SubscriptionService: Household updated - status: \(shoppingStatus ?? "nil"), shopperId: \(activeShopperId ?? "nil")")

                                self.lastHouseholdShoppingUpdate = HouseholdShoppingUpdate(
                                    householdId: id,
                                    shoppingStatus: shoppingStatus,
                                    activeShopperId: activeShopperId,
                                    shoppingStoreId: shoppingStoreId,
                                    shoppingStartedAt: shoppingStartedAt
                                )
                            }
                        case .failure(let error):
                            let errorMessage = parseGraphQLError(error)
                            print("SubscriptionService: Household subscription error - \(errorMessage)")
                            AmplifyService.shared.handleAuthError(error)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let errorMessage = error.localizedDescription
                    print("SubscriptionService: Household subscription fatal error - \(errorMessage)")
                    AmplifyService.shared.handleAuthError(error)
                }
            }
        }
    }

    private func subscribeToShoppingRequests(householdId: String) {
        shoppingRequestTask = Task {
            let document = """
            subscription OnCreateShoppingRequest {
              onCreateShoppingRequest {
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

            let request = GraphQLRequest<JSONValue>(
                document: document,
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let subscription = Amplify.API.subscribe(request: request)

            do {
                for try await subscriptionEvent in subscription {
                    switch subscriptionEvent {
                    case .connection(let state):
                        print("SubscriptionService: ShoppingRequest connection state: \(state)")
                        updateConnectionState(from: state)
                    case .data(let result):
                        switch result {
                        case .success(let json):
                            if let shoppingRequest = parseShoppingRequest(from: json, key: "onCreateShoppingRequest"),
                               shoppingRequest.householdId == householdId {
                                // Ensure user is cached for display
                                await ensureUserCached(shoppingRequest.requestedBy)
                                print("SubscriptionService: ShoppingRequest created: \(shoppingRequest.id)")
                                self.lastShoppingRequest = shoppingRequest
                            }
                        case .failure(let error):
                            let errorMessage = parseGraphQLError(error)
                            print("SubscriptionService: ShoppingRequest subscription error - \(errorMessage)")
                            AmplifyService.shared.handleAuthError(error)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let errorMessage = error.localizedDescription
                    print("SubscriptionService: ShoppingRequest subscription fatal error - \(errorMessage)")
                    AmplifyService.shared.handleAuthError(error)
                }
            }
        }
    }

    // MARK: - Error Parsing Helper

    private func parseGraphQLError(_ error: GraphQLResponseError<JSONValue>) -> String {
        switch error {
        case .error(let errors):
            return errors.map { $0.message }.joined(separator: "; ")
        case .partial(_, let errors):
            return errors.map { $0.message }.joined(separator: "; ")
        case .transformationError(_, let error):
            return "Transform error: \(error.localizedDescription)"
        case .unknown(let message, _, _):
            return message
        }
    }

    // MARK: - Connection State Helper

    private func updateConnectionState(from amplifyState: Any) {
        // Map Amplify subscription states to our connection state
        let stateString = String(describing: amplifyState)
        if stateString.contains("connecting") {
            connectionState = .connecting
        } else if stateString.contains("connected") {
            connectionState = .connected
        } else if stateString.contains("disconnected") {
            connectionState = .disconnected
        }
    }

    // MARK: - Parsing Helper

    private func parseGroceryItem(from json: JSONValue, key: String) -> GroceryItem? {
        guard case .object(let root) = json,
              case .object(let obj) = root[key],
              case .string(let id) = obj["id"],
              case .string(let householdId) = obj["householdId"],
              case .string(let name) = obj["name"],
              case .boolean(let isCustom) = obj["isCustom"],
              case .string(let statusString) = obj["status"],
              case .string(let addedBy) = obj["addedBy"] else {
            print("parseGroceryItem: Missing required field in JSON for key \(key)")
            return nil
        }

        let status: GroceryItem.ItemStatus
        switch statusString {
        case "IN_CART":
            status = .inCart
        case "SUGGESTION":
            status = .suggestion
        default:
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
            version: version
        )
    }

    private func parseShoppingRequest(from json: JSONValue, key: String) -> ShoppingRequest? {
        guard case .object(let root) = json,
              case .object(let obj) = root[key],
              case .string(let id) = obj["id"],
              case .string(let householdId) = obj["householdId"],
              case .string(let requestTypeString) = obj["requestType"],
              case .string(let itemName) = obj["itemName"],
              case .string(let requestedBy) = obj["requestedBy"],
              case .string(let statusString) = obj["status"] else {
            print("parseShoppingRequest: Missing required field in JSON for key \(key)")
            return nil
        }

        guard let requestType = ShoppingRequest.RequestType(rawValue: requestTypeString),
              let status = ShoppingRequest.RequestStatus(rawValue: statusString) else {
            print("parseShoppingRequest: Invalid enum value - requestType: \(requestTypeString), status: \(statusString)")
            return nil
        }

        var requestedAt = Date()
        if case .string(let requestedAtString) = obj["requestedAt"] {
            requestedAt = ISO8601DateFormatter().date(from: requestedAtString) ?? Date()
        }

        var resolvedAt: Date? = nil
        if case .string(let resolvedAtString) = obj["resolvedAt"] {
            resolvedAt = ISO8601DateFormatter().date(from: resolvedAtString)
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

    // MARK: - User Cache Helpers

    /// Ensure a single user is cached
    private func ensureUserCached(_ userId: String) async {
        if !UserCache.shared.hasUser(userId) {
            await UserCache.shared.fetchUser(userId)
        }
    }

    /// Ensure all users related to an item are cached
    private func ensureUsersCached(for item: GroceryItem) async {
        await ensureUserCached(item.addedBy)
        if let lockedBy = item.lockedBy {
            await ensureUserCached(lockedBy)
        }
    }
}
