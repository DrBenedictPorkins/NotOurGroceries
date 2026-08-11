import Foundation

/// Whether a store is organized into aisles at all.
/// Backend field is nullable — a missing value maps to `.aisles` for back-compat.
enum StoreLayoutType: String, Codable, Hashable, CaseIterable {
    case aisles = "AISLES"
    case noAisles = "NO_AISLES"
}

struct HouseholdStore: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let name: String
    var chain: String?
    var address: String?
    var aisleLayout: [StoreAisle]
    var layoutType: StoreLayoutType

    /// True when this store has no aisle organization at all (farmers market, corner shop).
    var hasNoAisles: Bool { layoutType == .noAisles }

    /// True when aisle-based navigation/inference should be attempted for this store.
    /// A store flagged AISLES but with an empty layout has nothing to infer against either.
    var supportsAisleNavigation: Bool { layoutType == .aisles && !aisleLayout.isEmpty }

    init(
        id: String = UUID().uuidString,
        householdId: String,
        name: String,
        chain: String? = nil,
        address: String? = nil,
        aisleLayout: [StoreAisle] = [],
        layoutType: StoreLayoutType = .aisles
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.chain = chain
        self.address = address
        self.aisleLayout = aisleLayout
        self.layoutType = layoutType
    }

    // Tolerant decoding: older payloads have no `layoutType` key at all.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        householdId = try container.decode(String.self, forKey: .householdId)
        name = try container.decode(String.self, forKey: .name)
        chain = try container.decodeIfPresent(String.self, forKey: .chain)
        address = try container.decodeIfPresent(String.self, forKey: .address)
        aisleLayout = try container.decodeIfPresent([StoreAisle].self, forKey: .aisleLayout) ?? []
        layoutType = try container.decodeIfPresent(StoreLayoutType.self, forKey: .layoutType) ?? .aisles
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
