import Foundation

struct HouseholdStore: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let name: String
    var chain: String?
    var address: String?
    var aisleLayout: [StoreAisle]

    /// The two kinds of aisle, and the kind that is not a store.
    ///
    /// - a **named department** — Produce, Bakery, Frozen — has no number, and
    ///   every store is seeded with all eighteen of them at creation;
    /// - a **numbered aisle** — 4, 12 — is the extra that larger shops add, and
    ///   is the only reason the directory scan exists;
    /// - a shop with neither is not a store in this app at all. That is a Quick
    ///   Trip.
    ///
    /// Numbered is a superset of named, not a rival kind, so there is no store
    /// *type* here and nothing to declare. A shop is created from home with its
    /// departments; the plaque gets scanned once somebody is standing in front of
    /// one; the layout gains numbered entries. Nothing converts, because there
    /// was never anything to convert between.
    ///
    /// That is also why the directory scan is offered on every store. Hiding it
    /// behind "this shop has numbered aisles" would be circular — scanning is how
    /// a shop comes to have them.
    ///
    /// There was a `supportsAisleNavigation` here asking whether the layout was
    /// empty, which stopped being answerable once every store was seeded, and a
    /// `hasNumberedAisles` after it that nothing ever consumed. Both gone; the
    /// distinction lives in the data, where `StoreAisle.number` either parses as
    /// a number or does not.

    init(
        id: String = UUID().uuidString,
        householdId: String,
        name: String,
        chain: String? = nil,
        address: String? = nil,
        aisleLayout: [StoreAisle] = []
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.chain = chain
        self.address = address
        self.aisleLayout = aisleLayout
    }

    // Tolerant decoding: `layoutType` may or may not be present, and is ignored
    // either way.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        householdId = try container.decode(String.self, forKey: .householdId)
        name = try container.decode(String.self, forKey: .name)
        chain = try container.decodeIfPresent(String.self, forKey: .chain)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        aisleLayout = try container.decodeIfPresent([StoreAisle].self, forKey: .aisleLayout) ?? []
    }
}

struct StoreAisle: Identifiable, Codable, Hashable {
    let id: String
    let number: String
    let name: String
    let displayOrder: Int
    var description: String?

    init(
        id: String = UUID().uuidString,
        number: String,
        name: String,
        displayOrder: Int,
        description: String? = nil
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.displayOrder = displayOrder
        self.description = description
    }
}

// MARK: - Preview Helpers
extension HouseholdStore {
    static var preview: HouseholdStore {
        HouseholdStore(
            id: "householdStore1",
            householdId: "household1",
            name: "Stop & Shop Stamford",
            chain: "Stop & Shop",
            address: "123 Main St, Stamford, CT 06902",
            aisleLayout: StoreAisle.previewList
        )
    }
}

extension StoreAisle {
    static var previewList: [StoreAisle] {
        [
            StoreAisle(
                id: "storeAisle1",
                number: "Produce",
                name: "Produce",
                displayOrder: 1
            ),
            StoreAisle(
                id: "storeAisle2",
                number: "3",
                name: "Dairy",
                displayOrder: 2
            ),
            StoreAisle(
                id: "storeAisle3",
                number: "7",
                name: "Breakfast",
                displayOrder: 3
            ),
            StoreAisle(
                id: "storeAisle4",
                number: "20-21",
                name: "Frozen",
                displayOrder: 4
            )
        ]
    }
}
