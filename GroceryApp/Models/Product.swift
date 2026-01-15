import Foundation

struct Product: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let normalizedName: String
    let aliases: [String]
    let category: String
    let storeAisleMappings: [String: String] // storeId: aisleId

    init(
        id: String = UUID().uuidString,
        name: String,
        normalizedName: String? = nil,
        aliases: [String] = [],
        category: String,
        storeAisleMappings: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.normalizedName = normalizedName ?? name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases
        self.category = category
        self.storeAisleMappings = storeAisleMappings
    }
}

// MARK: - Preview Helpers
extension Product {
    static var preview: Product {
        Product(
            id: "prod1",
            name: "Milk",
            aliases: ["Whole Milk", "2% Milk", "Skim Milk"],
            category: "Dairy",
            storeAisleMappings: [
                "store1": "aisle3",
                "store2": "aisle5"
            ]
        )
    }

    static var previewList: [Product] {
        [
            Product(id: "1", name: "Milk", aliases: ["Whole Milk"], category: "Dairy"),
            Product(id: "2", name: "Eggs", aliases: ["Large Eggs"], category: "Dairy"),
            Product(id: "3", name: "Bread", aliases: ["White Bread"], category: "Bakery"),
            Product(id: "4", name: "Apples", aliases: ["Red Apples"], category: "Produce"),
            Product(id: "5", name: "Chicken Breast", aliases: ["Boneless Chicken"], category: "Meat")
        ]
    }
}
