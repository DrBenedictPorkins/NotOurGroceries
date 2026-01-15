import Foundation

struct Aisle: Identifiable, Codable, Hashable {
    let id: String
    let storeId: String
    let number: String
    let name: String
    let displayOrder: Int
    let categories: [String]

    init(
        id: String = UUID().uuidString,
        storeId: String,
        number: String,
        name: String,
        displayOrder: Int,
        categories: [String]
    ) {
        self.id = id
        self.storeId = storeId
        self.number = number
        self.name = name
        self.displayOrder = displayOrder
        self.categories = categories
    }

    var displayName: String {
        if number.lowercased() == "produce" {
            return name
        }
        return "Aisle \(number) - \(name)"
    }
}

// MARK: - Preview Helpers
extension Aisle {
    static var previewList: [Aisle] {
        [
            Aisle(
                id: "aisle1",
                storeId: "store1",
                number: "Produce",
                name: "Produce",
                displayOrder: 1,
                categories: ["Fruits", "Vegetables"]
            ),
            Aisle(
                id: "aisle2",
                storeId: "store1",
                number: "3",
                name: "Dairy",
                displayOrder: 2,
                categories: ["Dairy", "Eggs", "Butter"]
            ),
            Aisle(
                id: "aisle3",
                storeId: "store1",
                number: "7",
                name: "Breakfast",
                displayOrder: 3,
                categories: ["Cereal", "Breakfast"]
            ),
            Aisle(
                id: "aisle4",
                storeId: "store1",
                number: "20-21",
                name: "Frozen",
                displayOrder: 4,
                categories: ["Frozen Foods", "Ice Cream"]
            )
        ]
    }
}
