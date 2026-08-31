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

    // MARK: - Standard Sections

    /// Perimeter sections present in virtually every US grocery store.
    /// These use stable deterministic IDs so we can detect if a store already has them.
    /// The order these appear in is the order you walk a shop.
    ///
    /// Three bands, and the gaps between them are the point:
    ///
    ///   -100…-1   perimeter — produce, bakery, deli, fish, meat, dairy
    ///    0…n      the store's own numbered aisles, from a directory scan
    ///    900+     centre-store named, then frozen last
    ///
    /// Numbered aisles land in the middle because that is where they are: you
    /// come in past the produce, walk the aisles, and finish at the freezers.
    ///
    /// The centre-store sections sit at the end on purpose. In a shop with
    /// numbered aisles they are not places — pasta and tinned tomatoes *are* the
    /// numbered aisles — so those sections only ever hold items inference could
    /// not pin down. Putting them first would send a shopper looking for shelves
    /// that do not exist. In a shop with no numbered aisles they are the whole
    /// middle of the walk, and with nothing in band 2 they follow the perimeter
    /// naturally.
    ///
    /// Frozen is deliberately last in both cases, because it melts.
    ///
    /// All of this is only a default. Aisle Management lets a store's order be
    /// dragged into whatever shape the real building has.
    static let namedDepartments: [StoreAisle] = [
        // Band 1 — the perimeter, in the order he has actually walked it: in past
        // the produce, bakery, then the deli and fish counters, the butcher, and
        // round to the chilled wall. Fish before meat because the counters
        // usually sit that way round.
        StoreAisle(id: "standard-produce",  number: "", name: "Produce",        displayOrder: -100, description: "Fresh fruits, vegetables, leafy greens, and fresh herbs"),
        StoreAisle(id: "standard-bakery",   number: "", name: "Bakery",         displayOrder: -95,  description: "Fresh bread, rolls, muffins, cakes, pastries, and baked goods"),
        StoreAisle(id: "standard-deli",     number: "", name: "Deli",           displayOrder: -90,  description: "Sliced meats, deli cheese, prepared foods, and cold cuts"),
        StoreAisle(id: "standard-seafood",  number: "", name: "Seafood",        displayOrder: -85,  description: "Fresh and packaged fish, shrimp, shellfish, and seafood"),
        StoreAisle(id: "standard-meat",     number: "", name: "Meat & Poultry", displayOrder: -80,  description: "Fresh and packaged beef, chicken, pork, turkey, lamb, and sausages"),
        StoreAisle(id: "standard-dairy",    number: "", name: "Dairy & Eggs",   displayOrder: -75,  description: "Milk, cream, yogurt, butter, cheese, eggs, and dairy alternatives"),

        // Band 3 — centre of the store. Before these existed the only sections
        // were the seven perimeter ones, so brown sugar and soy sauce had nowhere
        // to go: inference invented placeholder aisles, those got saved, and they
        // rendered as real section headers.
        StoreAisle(id: "standard-pantry",     number: "", name: "Pantry & Dry Goods", displayOrder: 900, description: "Flour, sugar, rice, pasta, beans, cereal, oats, and dry staples"),
        StoreAisle(id: "standard-canned",     number: "", name: "Canned Goods",       displayOrder: 901, description: "Canned vegetables, beans, soup, tuna, tomatoes, and broth"),
        StoreAisle(id: "standard-condiments", number: "", name: "Condiments & Sauces", displayOrder: 902, description: "Ketchup, mustard, mayo, salsa, soy sauce, oils, vinegar, and dressings"),
        StoreAisle(id: "standard-baking",     number: "", name: "Baking",             displayOrder: 903, description: "Baking mixes, brown sugar, chocolate chips, spices, and extracts"),
        StoreAisle(id: "standard-snacks",     number: "", name: "Snacks",             displayOrder: 904, description: "Chips, crackers, nuts, popcorn, cookies, and sweets"),
        StoreAisle(id: "standard-beverages",  number: "", name: "Beverages",          displayOrder: 905, description: "Water, juice, soda, coffee, tea, and drink mixes"),
        StoreAisle(id: "standard-personal",   number: "", name: "Personal Care",       displayOrder: 910, description: "Shampoo, soap, deodorant, toothpaste, razors, and cosmetics"),
        StoreAisle(id: "standard-pharmacy",   number: "", name: "Pharmacy & Health",   displayOrder: 911, description: "Over-the-counter medicine, sleep aids, vitamins, supplements, and first aid"),
        StoreAisle(id: "standard-baby",       number: "", name: "Baby",                displayOrder: 912, description: "Nappies, wipes, formula, baby food, and baby care"),
        StoreAisle(id: "standard-pet",        number: "", name: "Pet",                 displayOrder: 913, description: "Pet food, treats, litter, and pet supplies"),
        StoreAisle(id: "standard-household",  number: "", name: "Household",           displayOrder: 914, description: "Cleaning supplies, paper goods, foil, bags, trash bags, and laundry"),

        // Last on purpose.
        StoreAisle(id: "standard-frozen",   number: "", name: "Frozen",         displayOrder: 950, description: "Frozen vegetables, meals, pizza, ice cream, and frozen meats"),
    ]

    /// Adds any missing standard sections to a store and persists to backend.
    /// Safe to call repeatedly — only adds what isn't already there.
    func addMissingStandardSections(to store: HouseholdStore) async throws -> HouseholdStore {
        let existingIds = Set(store.aisleLayout.map { $0.id })
        let missing = Self.namedDepartments.filter { !existingIds.contains($0.id) }
        guard !missing.isEmpty else { return store }

        var updatedStore = store
        updatedStore.aisleLayout.append(contentsOf: missing)
        try await updateStore(updatedStore)
        return updatedStore
    }

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
                layoutType
            }
        }
        """

        // Every store gets the standard departments, including no-aisle ones.
        // They previously got nothing, which left a corner shop's list in no
        // order at all — but a shop without numbered aisles still has a cooler,
        // a produce rack and a bread shelf, and those are what these sections
        // are. "No aisles" means no numbers, not no organisation.
        let initialAisles: [[String: Any]] = Self.namedDepartments.map { aisle -> [String: Any] in
            var dict: [String: Any] = ["id": aisle.id, "number": aisle.number, "name": aisle.name, "displayOrder": aisle.displayOrder]
            if let description = aisle.description { dict["description"] = description }
            return dict
        }

        // AWSJSON goes over the wire as a serialized JSON *string*. A native array
        // is rejected with "Variable 'aisleLayout' has an invalid value" even when
        // it is perfectly well-formed — confirmed by logging the exact payload
        // against updateStore, which failed identically until it was encoded this
        // way. AppSync decodes the string, and DynamoDB stores a real list, so
        // nothing is double-encoded.
        //
        // This also removes the old special case for empty layouts: "[]" is a
        // valid JSON string, so there is no longer anything to omit.
        let aisleLayoutJSON = (try? JSONSerialization.data(withJSONObject: initialAisles))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let input: [String: Any] = [
            "id": storeId,
            "householdId": householdId,
            "name": name,
            "chain": chain ?? "",
            "layoutType": "AISLES",   // Schema field, kept satisfied; the app ignores it.
            "aisleLayout": aisleLayoutJSON
        ]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
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
                layoutType
            }
        }
        """

        // AWSJSON fields must be sent as native JSON values (arrays/objects),
        // NOT as JSON strings. DynamoDB S-type strings get double-encoded by AppSync.
        let aisleLayoutNative = store.aisleLayout.map { aisle -> [String: Any] in
            var dict: [String: Any] = [
                "id": aisle.id,
                "number": aisle.number,
                "name": aisle.name,
                "displayOrder": aisle.displayOrder
            ]
            if let description = aisle.description { dict["description"] = description }
            return dict
        }

        // AWSJSON as a *serialized string*. The native array is well-formed JSON
        // and AppSync still rejects it here with "Variable 'aisleLayout' has an
        // invalid value" — verified by logging the exact payload. The comment on
        // createStore claiming native is required appears to be wrong for update.
        let aisleLayoutJSON = (try? JSONSerialization.data(withJSONObject: aisleLayoutNative))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        var input: [String: Any] = [
            "id": store.id,
            "name": store.name,
            "aisleLayout": aisleLayoutJSON
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
                    layoutType
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
                displayOrder: index,
                description: aisle.description
            )
        }

        try await updateStore(updatedStore)
        return updatedStore
    }

    /// Reorder aisles in a store's layout
    func reorderAisles(in store: HouseholdStore, newOrder: [String]) async throws -> HouseholdStore {
        var updatedStore = store
        var reorderedAisles: [StoreAisle] = []

        // Anything not named in `newOrder` keeps its place at the end rather than
        // vanishing. This used to build the layout from `newOrder` alone, so an
        // aisle the caller had not listed — one added by a scan that finished
        // after the caller took its copy, say — was silently dropped from the
        // store. Reordering must not be able to lose an aisle.
        var placed = Set<String>()

        for aisleId in newOrder {
            guard let aisle = store.aisleLayout.first(where: { $0.id == aisleId }),
                  !placed.contains(aisle.id) else { continue }
            reorderedAisles.append(StoreAisle(
                id: aisle.id, number: aisle.number, name: aisle.name,
                displayOrder: reorderedAisles.count, description: aisle.description
            ))
            placed.insert(aisle.id)
        }

        for aisle in store.aisleLayout where !placed.contains(aisle.id) {
            reorderedAisles.append(StoreAisle(
                id: aisle.id, number: aisle.number, name: aisle.name,
                displayOrder: reorderedAisles.count, description: aisle.description
            ))
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

        // Reuse existing mapping ID if one exists, so DynamoDB UpdateItem updates in place
        let mappingId = productMappings[storeId]?.first(where: {
            (productId != nil && $0.productId == productId) ||
            (normalizedName != nil && $0.normalizedName == normalizedName)
        })?.id ?? UUID().uuidString

        // The resolver writes straight to the table, so it checks this against
        // the caller's group claim itself and stores it on the row. Taken from
        // the session rather than a parameter: you can only ever map a product
        // in the household you are signed into.
        guard let householdId = AmplifyService.shared.currentHouseholdId, !householdId.isEmpty else {
            throw NSError(domain: "StoreService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No household selected"])
        }

        let document = """
        mutation UpsertProductAisleMapping(
            $id: String!, $householdId: ID!, $storeId: ID!, $aisleId: String!, $productId: ID, $normalizedName: String
        ) {
            upsertProductAisleMapping(
                id: $id, householdId: $householdId, storeId: $storeId, aisleId: $aisleId,
                productId: $productId, normalizedName: $normalizedName
            ) {
                id
                storeId
                productId
                normalizedName
                aisleId
            }
        }
        """

        var variables: [String: Any] = [
            "id": mappingId,
            "householdId": householdId,
            "storeId": storeId,
            "aisleId": aisleId
        ]

        if let productId = productId {
            variables["productId"] = productId
        }
        if let normalizedName = normalizedName {
            variables["normalizedName"] = normalizedName
        }

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let response = try await Amplify.API.mutate(request: request)

        switch response {
        case .success(let json):
            if let mapping = parseProductAisleMapping(json, key: "upsertProductAisleMapping") {
                if productMappings[storeId] == nil {
                    productMappings[storeId] = []
                }
                productMappings[storeId]?.removeAll { $0.id == mapping.id }
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

    /// Delete mappings pointing at an aisle the store no longer declares.
    ///
    /// Inference could previously invent an aisle when nothing fit — literally
    /// "Not mapped (likely Baking/Dry Goods aisle)" — and that got saved and then
    /// rendered as a section header. Writes are guarded now, but the bad rows
    /// already exist, and because inference only runs for *unmapped* items they
    /// were self-perpetuating: re-running Map Aisles skipped them precisely
    /// because they were mapped.
    ///
    /// Matches the same id/name/number rule the display uses, so a mapping that
    /// resolves to a real aisle by any of those is kept.
    @discardableResult
    func pruneOrphanedMappings(storeId: String) async throws -> Int {
        guard let store = householdStores.first(where: { $0.id == storeId }) else { return 0 }
        let valid = Set(store.aisleLayout.flatMap { [$0.id, $0.name, $0.number] })
        guard !valid.isEmpty else { return 0 }

        let mappings = try await fetchMappings(storeId: storeId)
        var deleted = 0
        for mapping in mappings where !valid.contains(mapping.aisleId) {
            try await deleteMapping(id: mapping.id, storeId: storeId)
            deleted += 1
            print("[PRUNE] removed \(mapping.normalizedName ?? "?") -> \(mapping.aisleId)")
        }
        return deleted
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

        // `layoutType` still arrives from the backend and is deliberately not read.
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

        var description: String? = nil
        if case .string(let value) = obj["description"], !value.isEmpty {
            description = value
        }

        return StoreAisle(
            id: id,
            number: number,
            name: name,
            displayOrder: Int(displayOrder),
            description: description
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
