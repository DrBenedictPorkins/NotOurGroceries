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
    /// The seven departments every shop has, corner shop included.
    ///
    /// A department is a *place*: it has a sign over it and you walk to it. Eleven
    /// categories used to sit in here too — Canned Goods, Condiments & Sauces,
    /// Baking, Personal Care and the rest. They are not places. In a real shop
    /// "Condiments & Sauces" is *in* aisle 5, so offering it as a section header
    /// sent people to somewhere that does not exist.
    ///
    /// They were added to stop aisle inference inventing placeholder sections
    /// when it had nowhere to put brown sugar. Both halves of that reason are
    /// gone: inference now reads the store's own layout and cannot invent, and an
    /// item with no known aisle has an honest home in "No aisle yet", which one
    /// spoken aisle fixes for good. Across 1,306 mappings the eleven held 24
    /// between them, and four had never been used at all.
    ///
    /// A store has named departments and numbered aisles. There is no third kind.
    static let namedDepartments: [StoreAisle] = [
        // The perimeter, in the order it is actually walked: in past the produce,
        // bakery, then the deli and fish counters, the butcher, and round to the
        // chilled wall. Fish before meat because the counters usually sit that
        // way round.
        StoreAisle(id: "standard-produce",  number: "", name: "Produce",        displayOrder: -100, description: "Fresh fruits, vegetables, leafy greens, and fresh herbs"),
        StoreAisle(id: "standard-bakery",   number: "", name: "Bakery",         displayOrder: -95,  description: "Fresh bread, rolls, muffins, cakes, pastries, and baked goods"),
        StoreAisle(id: "standard-deli",     number: "", name: "Deli",           displayOrder: -90,  description: "Sliced meats, deli cheese, prepared foods, and cold cuts"),
        StoreAisle(id: "standard-seafood",  number: "", name: "Seafood",        displayOrder: -85,  description: "Fresh and packaged fish, shrimp, shellfish, and seafood"),
        StoreAisle(id: "standard-meat",     number: "", name: "Meat & Poultry", displayOrder: -80,  description: "Fresh and packaged beef, chicken, pork, turkey, lamb, and sausages"),
        StoreAisle(id: "standard-dairy",    number: "", name: "Dairy & Eggs",   displayOrder: -75,  description: "Milk, cream, yogurt, butter, cheese, eggs, and dairy alternatives"),

        // Last on purpose.
        StoreAisle(id: "standard-frozen",   number: "", name: "Frozen",         displayOrder: 950, description: "Frozen vegetables, meals, pizza, ice cream, and frozen meats"),
    ]

    /// Strips any `standard-` section that is not one of the seven.
    ///
    /// `namedDepartments` is a read-only template and this is what makes that
    /// true in practice rather than by convention. Every layout write in the app
    /// funnels through `updateStore`, so an eighth department cannot reach the
    /// backend from any path — not a new call site, not a stale client, not a
    /// well-meaning backfill.
    ///
    /// There was one of those. Eleven product categories — Baking, Snacks, Baby,
    /// Pharmacy & Health — were added as departments to give aisle inference
    /// somewhere to put brown sugar, and a backfill pushed them into every
    /// existing store. None of them is a place you can walk to. A supermarket has
    /// seven departments with signs over them; everything else is a numbered
    /// aisle that only the shopper can tell us about, and an item nobody has
    /// placed belongs in "No aisle yet", not in an invented section.
    ///
    /// Custom aisles are untouched — they carry UUIDs, not `standard-` ids, and
    /// adding them is the whole point.
    private func enforcingDepartmentTemplate(_ store: HouseholdStore) -> HouseholdStore {
        let allowed = Set(Self.namedDepartments.map(\.id))
        let offenders = store.aisleLayout.filter {
            $0.id.hasPrefix("standard-") && !allowed.contains($0.id)
        }
        guard !offenders.isEmpty else { return store }

        print("[DEPARTMENTS] refused \(offenders.count) non-template: \(offenders.map(\.id).joined(separator: ", "))")
        var cleaned = store
        cleaned.aisleLayout.removeAll { $0.id.hasPrefix("standard-") && !allowed.contains($0.id) }
        return cleaned
    }

    // MARK: - Store CRUD

    static let defaultStoreName = "My Store"
    static let deliStoreName = "Deli/Bodega"

    /// The small shop every household starts with, created once when the
    /// household is.
    ///
    /// A deli or bodega has no departments to walk to and no numbered aisles —
    /// a fridge, a counter, and shelves. Nothing to lay out, nothing to map, no
    /// AI to spend: all of that follows from an empty `aisleLayout` rather than
    /// from any stored store type, so nothing marks this row as special and
    /// nothing needs to.
    ///
    /// Done at household creation and never again. Seeding on every store fetch
    /// instead would mean checking for it by name, which makes deleting it or
    /// renaming it impossible — the next launch would put it straight back, or
    /// add a second one beside the renamed one. Once, here, is what lets the
    /// store behave like any other store afterwards.
    /// Both creates used to be `try?`, so a household that was seeded while the
    /// network was down came up with no stores at all and nothing said so —
    /// and because this runs once and is never retried, it stayed that way.
    /// The names that failed come back so the caller can say something.
    @discardableResult
    func seedStartingStores(householdId: String) async -> [String] {
        print("[STORES] New household — seeding its starting stores")
        var failed: [String] = []
        do {
            _ = try await createStore(
                name: Self.defaultStoreName,
                chain: nil,
                householdId: householdId
            )
        } catch {
            print("[STORES] Could not seed \(Self.defaultStoreName): \(error)")
            failed.append(Self.defaultStoreName)
        }
        do {
            _ = try await createStore(
                name: Self.deliStoreName,
                chain: nil,
                householdId: householdId,
                seedDepartments: false
            )
        } catch {
            print("[STORES] Could not seed \(Self.deliStoreName): \(error)")
            failed.append(Self.deliStoreName)
        }
        return failed
    }


    /// Is this name already on another store in the household?
    ///
    /// Two stores called the same thing are indistinguishable everywhere a
    /// store appears — the picker, the aisle screen's heading, "Selected …" —
    /// and each carries its own aisle layout, so picking the wrong one silently
    /// sends you to the wrong aisles. Compared trimmed and case-insensitively:
    /// "Stop & Shop" and "stop & shop " are the same shop.
    ///
    /// Pass the store's own id when renaming, so a store does not collide with
    /// itself.
    func nameIsTaken(_ name: String, excludingStoreId: String? = nil) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        return householdStores.contains {
            $0.id != excludingStoreId
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate
        }
    }

    /// Create a new store for a household
    func createStore(name: String, chain: String?, householdId: String, seedDepartments: Bool = true) async throws -> HouseholdStore {
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

        // Every store gets the standard departments, including no-aisle ones.
        // They previously got nothing, which left a corner shop's list in no
        // order at all — but a shop without numbered aisles still has a cooler,
        // a produce rack and a bread shelf, and those are what these sections
        // are. "No aisles" means no numbers, not no organisation.
        //
        // Unless there is nothing to seed. A corner deli in NYC has no produce
        // section and no bread aisle — it has a fridge and a counter — and seven
        // headings you cannot walk to is the same mistake the eleven categories
        // were. An empty layout needs no new flag or second kind of store: it is
        // simply a store whose `aisleLayout` is empty, which every screen already
        // handles. If the deli turns out to have a cooler after all, adding
        // "Dairy & Eggs" brings the real department back.
        let initialAisles: [[String: Any]] = !seedDepartments ? [] : Self.namedDepartments.map { aisle -> [String: Any] in
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
            "aisleLayout": aisleLayoutJSON
        ]

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: ["input": input],
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let json = try await API.mutate(request)

        guard let store = parseHouseholdStore(json, key: "createHouseholdStore") else {
            throw StoreServiceError.parseFailed("Failed to parse created store")
        }
        // Update local cache
        householdStores.append(store)
        return store
    }

    /// Update an existing store
    func updateStore(_ store: HouseholdStore) async throws {
        let store = enforcingDepartmentTemplate(store)
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

        let json = try await API.mutate(request)

        guard let updatedStore = parseHouseholdStore(json, key: "updateHouseholdStore") else {
            throw StoreServiceError.parseFailed("Failed to parse updated store")
        }
        // Update local cache
        if let index = householdStores.firstIndex(where: { $0.id == updatedStore.id }) {
            householdStores[index] = updatedStore
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

        _ = try await API.mutate(request)

        // Remove from local cache
        householdStores.removeAll { $0.id == storeId }
        productMappings.removeValue(forKey: storeId)
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

        let json = try await API.query(request)

        if case .object(let root) = json,
           case .object(let listResult) = root["storesByHousehold"],
           case .array(let items) = listResult["items"] {

            let stores = items.compactMap { parseHouseholdStore($0) }
            householdStores = stores
            return stores
        }
        return []
    }

    // MARK: - Aisle Management

    /// Add an aisle to a store's layout
    func addAisle(to store: HouseholdStore, number: String, name: String) async throws -> HouseholdStore {
        // Re-base on the freshest copy this service holds rather than trusting
        // the caller's snapshot. `aisleLayout` is written back whole, so two
        // saves a few seconds apart from a screen holding a stale store silently
        // dropped the first aisle — the mapping survived, pointing at an aisle no
        // longer in the layout, and the section header rendered a bare UUID.
        var updatedStore = householdStores.first { $0.id == store.id } ?? store

        // A new aisle 4 belongs between 3 and 5, not on the end. Appending was
        // fine when the whole layout arrived at once from a scan; now that aisles
        // are added one at a time, in the order somebody happens to find them,
        // appending puts 4 after 10 and the walk order is wrong from the start.
        //
        // Only numbered aisles are placed this way. A named department has no
        // natural position, and dragging is how a walk order gets set anyway —
        // this only has to pick a sensible place to start from.
        let slot = displayOrderForNewAisle(numbered: number, in: updatedStore.aisleLayout)

        // Everything at or past the slot shifts down. Bumping rather than
        // renumbering from zero keeps the gaps other code relies on, notably the
        // 900+ block the standard departments sit in.
        updatedStore.aisleLayout = updatedStore.aisleLayout.map { aisle in
            guard aisle.displayOrder >= slot else { return aisle }
            var shifted = aisle
            shifted.displayOrder += 1
            return shifted
        }

        // Typing "Bakery" back in after deleting it restores the department,
        // not a lookalike. A fresh UUID row would read identically on screen
        // while losing the description the inference prompt reads and the walk
        // -order slot `defaultAisleDisplayOrder` keys off `standard-` ids for.
        // This is what makes deleting a preset undoable without a reset button.
        let spoken = [number, name].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        if let template = Self.namedDepartments.first(where: {
            $0.name.lowercased() == spoken.trimmingCharacters(in: .whitespaces).lowercased()
        }) {
            updatedStore.aisleLayout.append(
                StoreAisle(id: template.id,
                           number: template.number,
                           name: template.name,
                           displayOrder: slot,
                           description: template.description)
            )
        } else {
            updatedStore.aisleLayout.append(
                StoreAisle(number: number, name: name, displayOrder: slot)
            )
        }

        try await updateStore(updatedStore)
        return updatedStore
    }

    /// Test seam for the placement rule, which is pure but sits on a service
    /// that otherwise needs a network.
    static func displayOrderForNewAisleForTesting(numbered number: String, in layout: [StoreAisle]) -> Int {
        shared.displayOrderForNewAisle(numbered: number, in: layout)
    }

    /// Where a newly added aisle should sit.
    ///
    /// For a numbered aisle, immediately before the lowest-numbered aisle that
    /// outranks it. For anything else, on the end.
    func displayOrderForNewAisle(numbered number: String, in layout: [StoreAisle]) -> Int {
        let end = (layout.map(\.displayOrder).max() ?? -1) + 1
        guard let value = Int(number.trimmingCharacters(in: .whitespaces)) else { return end }

        let successor = layout
            .compactMap { aisle -> (Int, Int)? in
                guard let n = Int(aisle.number.trimmingCharacters(in: .whitespaces)), n > value else { return nil }
                return (n, aisle.displayOrder)
            }
            .min { $0.0 < $1.0 }

        return successor?.1 ?? end
    }

    /// Correct an aisle's label, keeping its identity.
    ///
    /// The id never changes, so every mapping pointing at this aisle keeps
    /// pointing at it. That is what makes renaming a preset department safe:
    /// `standard-produce` stays `standard-produce` whether it reads "Produce" or
    /// "Fruit & Veg", and the description the inference prompt reads is left
    /// alone.
    ///
    /// A bare integer is an aisle number, anything else is a name — the same
    /// split `AisleUtterance` makes, so a typed correction and a spoken one
    /// cannot disagree about what an aisle is.
    func renameAisle(in store: HouseholdStore, aisleId: String, to label: String) async throws -> HouseholdStore {
        var updatedStore = householdStores.first { $0.id == store.id } ?? store
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return updatedStore }

        let isNumber = Int(trimmed) != nil
        updatedStore.aisleLayout = updatedStore.aisleLayout.map { aisle in
            guard aisle.id == aisleId else { return aisle }
            return StoreAisle(
                id: aisle.id,
                number: isNumber ? trimmed : "",
                name: isNumber ? "" : trimmed,
                displayOrder: aisle.displayOrder,
                description: aisle.description
            )
        }

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

    /// Assign a product to an aisle in a specific store.
    ///
    /// `sightedByUser` is for aisle capture: somebody stood in the shop and read
    /// the sign. That writes `userAisleOverride` as well, which is the field that
    /// wins at read time and — unlike `aisleId` — no later inference run touches.
    func assignProductToAisle(
        productId: String?,
        normalizedName: String?,
        storeId: String,
        aisleId: String,
        sightedByUser: Bool = false
    ) async throws {
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
            $id: String!, $householdId: ID!, $storeId: ID!, $aisleId: String!, $productId: ID, $normalizedName: String,
            $userAisleOverride: String, $source: String
        ) {
            upsertProductAisleMapping(
                id: $id, householdId: $householdId, storeId: $storeId, aisleId: $aisleId,
                productId: $productId, normalizedName: $normalizedName,
                userAisleOverride: $userAisleOverride, source: $source
            ) {
                id
                storeId
                productId
                normalizedName
                aisleId
                userAisleOverride
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
        if sightedByUser {
            variables["userAisleOverride"] = aisleId
            variables["source"] = MappingSource.userSighted.rawValue
        }

        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: variables,
            responseType: JSONValue.self,
                authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        let json = try await API.mutate(request)

        if let mapping = parseProductAisleMapping(json, key: "upsertProductAisleMapping") {
            // Animated, because this is what moves an item from one aisle
            // heading to another on the At Store screen. Without it the row
            // vanishes from where you were looking and reappears somewhere
            // else in the same frame, which reads as the item being deleted —
            // it was reported as exactly that. Same spring as moving an item
            // to suggestions, so the two transitions feel like one app.
            //
            // Here rather than at the call sites: typing an aisle, saying one
            // out loud and the batch mapper all come through this function.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                if productMappings[storeId] == nil {
                    productMappings[storeId] = []
                }
                productMappings[storeId]?.removeAll { $0.id == mapping.id }
                productMappings[storeId]?.append(mapping)
            }
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

        _ = try await API.mutate(request)

        // Update local cache
        productMappings[storeId]?.removeAll { $0.id == mapping.id }
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

        _ = try await API.mutate(request)

        productMappings[storeId]?.removeAll { $0.id == id }
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

            let json = try await API.query(request)

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
        } while nextToken != nil

        // Animated for the same reason as the upsert above: this lands right
        // after a save and would otherwise snap the row into place a second time.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            productMappings[storeId] = allMappings
        }
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
        do {
            _ = try await fetchStores(householdId: householdId)
        } catch {
            print("[STORES] Refresh of stores failed: \(ServiceFailure.from(error).errorDescription ?? "")")
        }
        for store in householdStores {
            do {
                _ = try await fetchMappings(storeId: store.id)
            } catch {
                print("[STORES] Refresh of mappings for \(store.id) failed: \(ServiceFailure.from(error).errorDescription ?? "")")
            }
        }
    }

    // MARK: - Parsing Helpers

    /// Stores from the launch handshake.
    func apply(stores json: [JSONValue]) {
        let parsed = json.compactMap { parseHouseholdStore($0) }
        guard !parsed.isEmpty else { return }
        householdStores = parsed
    }

    func parseHouseholdStore(_ json: JSONValue, key: String? = nil) -> HouseholdStore? {
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

        // There was a `layoutType` on this model declaring a store "aisled" or
        // "no aisles". It was written as a constant, never read, and described a
        // distinction that does not exist — numbered aisles are an addition to the
        // named departments every store has, not a rival kind of shop.
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
