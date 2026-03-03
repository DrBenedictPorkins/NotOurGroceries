import Foundation
import SwiftUI
import Amplify
import AWSPluginsCore

// MARK: - Service

@MainActor
class StoreService: ObservableObject {
    static let shared = StoreService()

    @Published var householdStores: [HouseholdStore] = []
    @Published var productMappings: [String: [ProductAisleMapping]] = [:] // storeId -> mappings

    private init() {}

    // MARK: - Store CRUD

    /// Create a new store for a household
    func createStore(name: String, chain: String?, householdId: String) async throws -> HouseholdStore {
        let storeId = UUID().uuidString

        let document = """
        mutation CreateHouseholdStore($input: CreateHouseholdStoreInput!) {
            createHouseholdStore(input: $input) {
                id
                householdId
                name
                chain
                address
                aisleLayout
            }
        }
        """

        // AWSJSON fields must be sent as native JSON values (arrays/objects),
        // NOT as JSON strings. DynamoDB S-type strings get double-encoded by AppSync.
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "input": [
                    "id": storeId,
                    "householdId": householdId,
                    "name": name,
                    "chain": chain ?? ""
                ]
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            if let store = parseHouseholdStore(json, key: "createHouseholdStore") {
                // Update local cache
                householdStores.append(store)
                return store
            }
            throw StoreServiceError.parseFailed("Failed to parse created store")
        case .failure(let error):
            throw error
        }
    }

    /// Update an existing store
    func updateStore(_ store: HouseholdStore) async throws {
        let document = """
        mutation UpdateHouseholdStore($input: UpdateHouseholdStoreInput!) {
            updateHouseholdStore(input: $input) {
                id
                householdId
                name
                chain
                address
                aisleLayout
            }
        }
        """

        // AWSJSON fields must be sent as native JSON values (arrays/objects),
        // NOT as JSON strings. DynamoDB S-type strings get double-encoded by AppSync.
        let aisleLayoutNative = store.aisleLayout.map { aisle -> [String: Any] in
            return [
                "id": aisle.id,
                "number": aisle.number,
                "name": aisle.name,
                "displayOrder": aisle.displayOrder
            ]
        }

        var input: [String: Any] = [
            "id": store.id,
            "name": store.name,
            "aisleLayout": aisleLayoutNative
        ]

        // Add optional fields
        if let chain = store.chain {
            input["chain"] = chain
        }
        if let address = store.address {
            input["address"] = address
        }

        let variables: [String: Any] = ["input": input]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            if let updatedStore = parseHouseholdStore(json, key: "updateHouseholdStore") {
                // Update local cache
                if let index = householdStores.firstIndex(where: { $0.id == updatedStore.id }) {
                    householdStores[index] = updatedStore
                }
            } else {
                throw StoreServiceError.parseFailed("Failed to parse updated store")
            }
        case .failure(let error):
            throw error
        }
    }

    /// Delete a store
    func deleteStore(_ storeId: String) async throws {
        let document = """
        mutation DeleteHouseholdStore($input: DeleteHouseholdStoreInput!) {
            deleteHouseholdStore(input: $input) {
                id
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "input": [
                    "id": storeId
                ]
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success:
            // Remove from local cache
            householdStores.removeAll { $0.id == storeId }
            productMappings.removeValue(forKey: storeId)
        case .failure(let error):
            throw error
        }
    }

    /// Fetch all stores for a household
    func fetchStores(householdId: String) async throws -> [HouseholdStore] {
        let document = """
        query StoresByHousehold($householdId: ID!) {
            storesByHousehold(householdId: $householdId) {
                items {
                    id
                    householdId
                    name
                    chain
                    address
                    aisleLayout
                }
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["householdId": householdId],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.query(request: request)

        switch response {
        case .success(let json):
            if case .object(let root) = json,
               case .object(let listResult) = root["storesByHousehold"],
               case .array(let items) = listResult["items"] {

                let stores = items.compactMap { parseHouseholdStore($0) }
                householdStores = stores
                return stores
            }
            return []
        case .failure(let error):
            throw error
        }
    }

    // MARK: - Aisle Management

    /// Add an aisle to a store's layout
    func addAisle(to store: HouseholdStore, number: String, name: String) async throws -> HouseholdStore {
        var updatedStore = store
        let newAisle = StoreAisle(
            number: number,
            name: name,
            displayOrder: store.aisleLayout.count
        )
        updatedStore.aisleLayout.append(newAisle)

        try await updateStore(updatedStore)
        return updatedStore
    }

    /// Remove an aisle from a store's layout
    func removeAisle(from store: HouseholdStore, aisleId: String) async throws -> HouseholdStore {
        var updatedStore = store
        updatedStore.aisleLayout.removeAll { $0.id == aisleId }

        // Reorder display orders
        updatedStore.aisleLayout = updatedStore.aisleLayout.enumerated().map { index, aisle in
            StoreAisle(
                id: aisle.id,
                number: aisle.number,
                name: aisle.name,
                displayOrder: index
            )
        }

        try await updateStore(updatedStore)
        return updatedStore
    }

    /// Reorder aisles in a store's layout
    func reorderAisles(in store: HouseholdStore, newOrder: [String]) async throws -> HouseholdStore {
        var updatedStore = store
        var reorderedAisles: [StoreAisle] = []

        for (index, aisleId) in newOrder.enumerated() {
            if let aisle = store.aisleLayout.first(where: { $0.id == aisleId }) {
                reorderedAisles.append(StoreAisle(
                    id: aisle.id,
                    number: aisle.number,
                    name: aisle.name,
                    displayOrder: index
                ))
            }
        }

        updatedStore.aisleLayout = reorderedAisles
        try await updateStore(updatedStore)
        return updatedStore
    }

    // MARK: - Product Mapping

    /// Assign a product to an aisle in a specific store
    func assignProductToAisle(productId: String?, normalizedName: String?, storeId: String, aisleId: String) async throws {
        guard productId != nil || normalizedName != nil else {
            throw StoreServiceError.invalidMapping("Either productId or normalizedName must be provided")
        }

        let mappingId = UUID().uuidString

        let document = """
        mutation CreateProductAisleMapping($input: CreateProductAisleMappingInput!) {
            createProductAisleMapping(input: $input) {
                id
                storeId
                productId
                normalizedName
                aisleId
            }
        }
        """

        var input: [String: Any] = [
            "id": mappingId,
            "storeId": storeId,
            "aisleId": aisleId
        ]

        if let productId = productId {
            input["productId"] = productId
        }
        if let normalizedName = normalizedName {
            input["normalizedName"] = normalizedName
        }

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            if let mapping = parseProductAisleMapping(json, key: "createProductAisleMapping") {
                // Update local cache
                if productMappings[storeId] == nil {
                    productMappings[storeId] = []
                }
                productMappings[storeId]?.append(mapping)
            }
        case .failure(let error):
            throw error
        }
    }

    /// Remove a product-to-aisle mapping
    func removeMapping(storeId: String, productId: String?, normalizedName: String?) async throws {
        // First, find the mapping ID
        let mappings = try await fetchMappings(storeId: storeId)

        guard let mapping = mappings.first(where: {
            (productId != nil && $0.productId == productId) ||
            (normalizedName != nil && $0.normalizedName == normalizedName)
        }) else {
            throw StoreServiceError.mappingNotFound("No mapping found for specified product")
        }

        let document = """
        mutation DeleteProductAisleMapping($input: DeleteProductAisleMappingInput!) {
            deleteProductAisleMapping(input: $input) {
                id
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "input": [
                    "id": mapping.id
                ]
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success:
            // Update local cache
            productMappings[storeId]?.removeAll { $0.id == mapping.id }
        case .failure(let error):
            throw error
        }
    }

    /// Delete a mapping by ID directly
    func deleteMapping(id: String, storeId: String) async throws {
        let document = """
        mutation DeleteProductAisleMapping($input: DeleteProductAisleMappingInput!) {
            deleteProductAisleMapping(input: $input) {
                id
            }
        }
        """

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: [
                "input": [
                    "id": id
                ]
            ],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success:
            productMappings[storeId]?.removeAll { $0.id == id }
        case .failure(let error):
            throw error
        }
    }

    /// Clean up mappings with invalid aisleIds (UUIDs instead of real aisle names)
    func cleanupInvalidMappings(storeId: String) async throws -> Int {
        let mappings = try await fetchMappings(storeId: storeId)

        // UUID pattern: 8-4-4-4-12 hex characters
        let uuidPattern = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        let uuidRegex = try? NSRegularExpression(pattern: uuidPattern)

        var deletedCount = 0

        for mapping in mappings {
            let aisleId = mapping.aisleId
            let range = NSRange(aisleId.startIndex..., in: aisleId)

            // Check if aisleId looks like a UUID
            if uuidRegex?.firstMatch(in: aisleId, range: range) != nil {
                try await deleteMapping(id: mapping.id, storeId: storeId)
                deletedCount += 1
            }
        }

        return deletedCount
    }

    /// Fetch all product mappings for a store (with pagination)
    func fetchMappings(storeId: String) async throws -> [ProductAisleMapping] {
        let document = """
        query MappingsByStore($storeId: ID!, $limit: Int, $nextToken: String) {
            mappingsByStore(storeId: $storeId, limit: $limit, nextToken: $nextToken) {
                items {
                    id
                    storeId
                    productId
                    normalizedName
                    aisleId
                    confidence
                    source
                    userAisleOverride
                    reasoning
                    sourceImageKeys
                    mappedAt
                }
                nextToken
            }
        }
        """

        var allMappings: [ProductAisleMapping] = []
        var nextToken: String? = nil

        repeat {
            var variables: [String: Any] = [
                "storeId": storeId,
                "limit": 500
            ]
            if let token = nextToken {
                variables["nextToken"] = token
            }

            let request = GraphQLRequest<JSONValue>(
                document: document,
                variables: variables,
                responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
            )

            let response = try await Amplify.API.query(request: request)

            switch response {
            case .success(let json):
                if case .object(let root) = json,
                   case .object(let listResult) = root["mappingsByStore"],
                   case .array(let items) = listResult["items"] {

                    let mappings = items.compactMap { parseProductAisleMapping($0) }
                    allMappings.append(contentsOf: mappings)

                    // Check for next page
                    if case .string(let token) = listResult["nextToken"] {
                        nextToken = token
                    } else {
                        nextToken = nil
                    }
                } else {
                    nextToken = nil
                }
            case .failure(let error):
                throw error
            }
        } while nextToken != nil

        productMappings[storeId] = allMappings
        return allMappings
    }

    // MARK: - Helper Methods

    /// Returns a sensible default display order based on typical US supermarket layout
    /// Used when aisles don't have explicit displayOrder set
    static func defaultAisleDisplayOrder(for aisleId: String) -> Int {
        // Default order for common US supermarket sections
        let defaultOrder: [String: Int] = [
            "Unknown": 0,
            "Produce": 1,
            "Bakery": 2,
            "Deli": 3,
            "Seafood": 4,
            "Meat": 5,
            "Meats": 5,
            // Numbered aisles (1-99) get 100 + number
            "Frozen": 200,
            "Dairy": 201
        ]

        let lowerAisle = aisleId.lowercased()

        // Check exact matches first
        for (key, order) in defaultOrder {
            if key.lowercased() == lowerAisle {
                return order
            }
        }

        // Numbered aisles get 100 + their number
        if let num = Int(aisleId) {
            return 100 + num
        }

        // Unknown aisles default to middle
        return 150
    }

    /// Look up the effective aisle ID for a product in a specific store
    /// Returns the user override if present, otherwise the LLM suggestion
    func aisleId(for productId: String?, normalizedName: String?, in storeId: String) -> String? {
        guard let mappings = productMappings[storeId] else { return nil }

        // Try matching by productId first
        if let productId = productId,
           let mapping = mappings.first(where: { $0.productId == productId }) {
            return mapping.effectiveAisle
        }

        // Fall back to normalizedName
        if let normalizedName = normalizedName,
           let mapping = mappings.first(where: { $0.normalizedName == normalizedName }) {
            return mapping.effectiveAisle
        }

        return nil
    }

    /// Look up the full mapping for a product in a specific store
    func mapping(for productId: String?, normalizedName: String?, in storeId: String) -> ProductAisleMapping? {
        guard let mappings = productMappings[storeId] else { return nil }

        // Try matching by productId first
        if let productId = productId,
           let mapping = mappings.first(where: { $0.productId == productId }) {
            return mapping
        }

        // Fall back to normalizedName
        if let normalizedName = normalizedName,
           let mapping = mappings.first(where: { $0.normalizedName == normalizedName }) {
            return mapping
        }

        return nil
    }

    /// Simple lookup by productId - no fuzzy matching needed (LLM handles that)
    func getAisleMapping(productId: String?, storeId: String) -> ProductAisleMapping? {
        guard let productId = productId,
              let mappings = productMappings[storeId] else { return nil }
        return mappings.first { $0.productId == productId }
    }

    /// Get all mappings with low confidence for a store
    func lowConfidenceMappings(in storeId: String) -> [ProductAisleMapping] {
        guard let mappings = productMappings[storeId] else { return [] }
        return mappings.filter { $0.isLowConfidence && !$0.hasUserOverride }
    }

    /// Get all mappings with user overrides for a store
    func userOverriddenMappings(in storeId: String) -> [ProductAisleMapping] {
        guard let mappings = productMappings[storeId] else { return [] }
        return mappings.filter { $0.hasUserOverride }
    }

    /// Refresh all store data for a household (stores and their mappings)
    func refreshAllForHousehold(_ householdId: String) async {
        _ = try? await fetchStores(householdId: householdId)
        for store in householdStores {
            _ = try? await fetchMappings(storeId: store.id)
        }
    }

    // MARK: - Parsing Helpers

    private func parseHouseholdStore(_ json: JSONValue, key: String? = nil) -> HouseholdStore? {
        let storeData: JSONValue
        if let key = key {
            guard case .object(let root) = json,
                  let data = root[key] else {
                return nil
            }
            storeData = data
        } else {
            storeData = json
        }

        guard case .object(let obj) = storeData,
              case .string(let id) = obj["id"],
              case .string(let householdId) = obj["householdId"],
              case .string(let name) = obj["name"] else {
            return nil
        }

        var chain: String? = nil
        if case .string(let chainValue) = obj["chain"], !chainValue.isEmpty {
            chain = chainValue
        }

        var address: String? = nil
        if case .string(let addressValue) = obj["address"], !addressValue.isEmpty {
            address = addressValue
        }

        var aisleLayout: [StoreAisle] = []
        if case .string(let aisleLayoutString) = obj["aisleLayout"],
           let data = aisleLayoutString.data(using: .utf8) {
            // Try direct decode (DynamoDB L-type → AppSync single-encoded string)
            if let decoded = try? JSONDecoder().decode([StoreAisle].self, from: data) {
                aisleLayout = decoded
            } else if let innerString = try? JSONDecoder().decode(String.self, from: data),
                      let innerData = innerString.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode([StoreAisle].self, from: innerData) {
                // Handle double-encoded legacy data (DynamoDB S-type → AppSync double-encoded)
                aisleLayout = decoded
            }
        } else if case .array(let aisleArray) = obj["aisleLayout"] {
            aisleLayout = aisleArray.compactMap { parseStoreAisle($0) }
        }

        return HouseholdStore(
            id: id,
            householdId: householdId,
            name: name,
            chain: chain,
            address: address,
            aisleLayout: aisleLayout
        )
    }

    private func parseStoreAisle(_ json: JSONValue) -> StoreAisle? {
        guard case .object(let obj) = json,
              case .string(let id) = obj["id"],
              case .string(let number) = obj["number"],
              case .string(let name) = obj["name"],
              case .number(let displayOrder) = obj["displayOrder"] else {
            return nil
        }

        return StoreAisle(
            id: id,
            number: number,
            name: name,
            displayOrder: Int(displayOrder)
        )
    }

    private func parseProductAisleMapping(_ json: JSONValue, key: String? = nil) -> ProductAisleMapping? {
        let mappingData: JSONValue
        if let key = key {
            guard case .object(let root) = json,
                  let data = root[key] else {
                return nil
            }
            mappingData = data
        } else {
            mappingData = json
        }

        guard case .object(let obj) = mappingData,
              case .string(let id) = obj["id"],
              case .string(let storeId) = obj["storeId"],
              case .string(let aisleId) = obj["aisleId"] else {
            return nil
        }

        var productId: String? = nil
        if case .string(let value) = obj["productId"], !value.isEmpty {
            productId = value
        }

        var normalizedName: String? = nil
        if case .string(let value) = obj["normalizedName"], !value.isEmpty {
            normalizedName = value
        }

        var confidence: Double? = nil
        if case .number(let value) = obj["confidence"] {
            confidence = value
        }

        var source: MappingSource? = nil
        if case .string(let value) = obj["source"] {
            source = MappingSource(rawValue: value)
        }

        var userAisleOverride: String? = nil
        if case .string(let value) = obj["userAisleOverride"], !value.isEmpty {
            userAisleOverride = value
        }

        var reasoning: String? = nil
        if case .string(let value) = obj["reasoning"], !value.isEmpty {
            reasoning = value
        }

        var sourceImageKeys: [String]? = nil
        if case .array(let keysArray) = obj["sourceImageKeys"] {
            sourceImageKeys = keysArray.compactMap { item in
                if case .string(let key) = item { return key }
                return nil
            }
        }

        var mappedAt: Date? = nil
        if case .string(let dateString) = obj["mappedAt"] {
            mappedAt = ISO8601DateFormatter().date(from: dateString)
        }

        return ProductAisleMapping(
            id: id,
            storeId: storeId,
            productId: productId,
            normalizedName: normalizedName,
            aisleId: aisleId,
            confidence: confidence,
            source: source,
            userAisleOverride: userAisleOverride,
            reasoning: reasoning,
            sourceImageKeys: sourceImageKeys,
            mappedAt: mappedAt
        )
    }

}

// MARK: - Errors

enum StoreServiceError: LocalizedError {
    case parseFailed(String)
    case invalidMapping(String)
    case mappingNotFound(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let message),
             .invalidMapping(let message),
             .mappingNotFound(let message):
            return message
        }
    }
}
