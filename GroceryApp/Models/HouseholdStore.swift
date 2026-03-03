import Foundation

struct HouseholdStore: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let name: String
    var chain: String?
    var address: String?
    var aisleLayout: [StoreAisle]

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
