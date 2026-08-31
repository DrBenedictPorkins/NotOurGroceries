import Foundation

struct HouseholdStore: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let name: String
    var chain: String?
    var address: String?
    var aisleLayout: [StoreAisle]

    /// Whether this shop numbers its aisles, on top of the named departments
    /// every shop has.
    ///
    /// The vocabulary, which the code used to muddle:
    ///
    /// - a **named department** — Produce, Bakery, Frozen — has no number, and
    ///   every store is seeded with all eighteen of them at creation;
    /// - a **numbered aisle** — 4, 12 — is the extra that larger shops add, and
    ///   is the only reason the directory scan exists;
    /// - a shop with neither is not a store in this app at all. That is a Quick
    ///   Trip.
    ///
    /// So numbered is a superset of named, not a rival kind, and this is derived
    /// rather than declared. Nobody is asked which sort of shop they are standing
    /// in — a question they often cannot answer until they get there. Create the
    /// store from home with just its departments, scan the plaque once you see
    /// one, and the layout gains numbered entries and this turns true on its own.
    ///
    /// It replaced `supportsAisleNavigation`, which asked whether the layout was
    /// empty. That could not be false once every store was seeded, so it was a
    /// question with one answer, and the branches behind it were unreachable.
    var hasNumberedAisles: Bool {
        aisleLayout.contains { Int($0.number.trimmingCharacters(in: .whitespaces)) != nil }
    }

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
