import XCTest
@testable import GroceryApp

final class ProductTests: XCTestCase {

    // MARK: - Initialization Tests

    func testProduct_DefaultInitialization_SetsDefaultValues() {
        // Given / When
        let product = Product(name: "Milk", category: "Dairy")

        // Then
        XCTAssertFalse(product.id.isEmpty, "Should generate a non-empty ID")
        XCTAssertEqual(product.name, "Milk")
        XCTAssertEqual(product.normalizedName, "milk", "Should auto-normalize name")
        XCTAssertEqual(product.aliases, [], "Should default aliases to empty array")
        XCTAssertEqual(product.category, "Dairy")
        XCTAssertEqual(product.storeAisleMappings, [:], "Should default mappings to empty dictionary")
    }

    func testProduct_WithAllParameters_SetsAllValues() {
        // Given
        let id = "prod123"
        let name = "Milk"
        let normalizedName = "milk"
        let aliases = ["Whole Milk", "2% Milk", "Skim Milk"]
        let category = "Dairy"
        let mappings = ["store1": "aisle3", "store2": "aisle5"]

        // When
        let product = Product(
            id: id,
            name: name,
            normalizedName: normalizedName,
            aliases: aliases,
            category: category,
            storeAisleMappings: mappings
        )

        // Then
        XCTAssertEqual(product.id, id)
        XCTAssertEqual(product.name, name)
        XCTAssertEqual(product.normalizedName, normalizedName)
        XCTAssertEqual(product.aliases, aliases)
        XCTAssertEqual(product.category, category)
        XCTAssertEqual(product.storeAisleMappings, mappings)
    }

    func testProduct_NormalizedNameAutoGeneration_TrimsAndLowercases() {
        // Given / When
        let product = Product(name: "  MILK  ", category: "Dairy")

        // Then
        XCTAssertEqual(product.normalizedName, "milk")
    }

    func testProduct_WithCustomNormalizedName_UsesProvidedValue() {
        // Given / When
        let product = Product(name: "Milk", normalizedName: "custom-milk", category: "Dairy")

        // Then
        XCTAssertEqual(product.normalizedName, "custom-milk")
    }

    func testProduct_WithEmptyName_CreatesNormalizedName() {
        // Given / When
        let product = Product(name: "", category: "Dairy")

        // Then
        XCTAssertEqual(product.normalizedName, "")
    }

    func testProduct_WithWhitespaceOnlyName_CreatesEmptyNormalizedName() {
        // Given / When
        let product = Product(name: "   ", category: "Dairy")

        // Then
        XCTAssertEqual(product.normalizedName, "")
    }

    func testProduct_WithMultipleAliases_StoresAllAliases() {
        // Given
        let aliases = ["Whole Milk", "2% Milk", "Skim Milk", "Low-Fat Milk"]

        // When
        let product = Product(name: "Milk", aliases: aliases, category: "Dairy")

        // Then
        XCTAssertEqual(product.aliases.count, 4)
        XCTAssertTrue(product.aliases.contains("Whole Milk"))
        XCTAssertTrue(product.aliases.contains("2% Milk"))
        XCTAssertTrue(product.aliases.contains("Skim Milk"))
        XCTAssertTrue(product.aliases.contains("Low-Fat Milk"))
    }

    func testProduct_WithStoreAisleMappings_StoresAllMappings() {
        // Given
        let mappings = [
            "store1": "aisle3",
            "store2": "aisle5",
            "store3": "aisle7"
        ]

        // When
        let product = Product(name: "Milk", category: "Dairy", storeAisleMappings: mappings)

        // Then
        XCTAssertEqual(product.storeAisleMappings.count, 3)
        XCTAssertEqual(product.storeAisleMappings["store1"], "aisle3")
        XCTAssertEqual(product.storeAisleMappings["store2"], "aisle5")
        XCTAssertEqual(product.storeAisleMappings["store3"], "aisle7")
    }

    // MARK: - Codable Tests

    func testProduct_Encodable_CanEncodeToJSON() throws {
        // Given
        let product = Product(
            id: "prod123",
            name: "Milk",
            normalizedName: "milk",
            aliases: ["Whole Milk", "2% Milk"],
            category: "Dairy",
            storeAisleMappings: ["store1": "aisle3"]
        )

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(product)

        // Then
        XCTAssertFalse(data.isEmpty)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["id"] as? String, "prod123")
        XCTAssertEqual(json?["name"] as? String, "Milk")
        XCTAssertEqual(json?["category"] as? String, "Dairy")
    }

    func testProduct_Decodable_CanDecodeFromJSON() throws {
        // Given
        let json = """
        {
            "id": "prod123",
            "name": "Milk",
            "normalizedName": "milk",
            "aliases": ["Whole Milk", "2% Milk"],
            "category": "Dairy",
            "storeAisleMappings": {
                "store1": "aisle3",
                "store2": "aisle5"
            }
        }
        """

        // When
        let decoder = JSONDecoder()
        let data = json.data(using: .utf8)!
        let product = try decoder.decode(Product.self, from: data)

        // Then
        XCTAssertEqual(product.id, "prod123")
        XCTAssertEqual(product.name, "Milk")
        XCTAssertEqual(product.normalizedName, "milk")
        XCTAssertEqual(product.aliases.count, 2)
        XCTAssertTrue(product.aliases.contains("Whole Milk"))
        XCTAssertEqual(product.category, "Dairy")
        XCTAssertEqual(product.storeAisleMappings["store1"], "aisle3")
        XCTAssertEqual(product.storeAisleMappings["store2"], "aisle5")
    }

    func testProduct_Decodable_WithEmptyArraysAndDictionaries() throws {
        // Given
        let json = """
        {
            "id": "prod123",
            "name": "Milk",
            "normalizedName": "milk",
            "aliases": [],
            "category": "Dairy",
            "storeAisleMappings": {}
        }
        """

        // When
        let decoder = JSONDecoder()
        let data = json.data(using: .utf8)!
        let product = try decoder.decode(Product.self, from: data)

        // Then
        XCTAssertEqual(product.aliases, [])
        XCTAssertEqual(product.storeAisleMappings, [:])
    }

    // MARK: - Hashable Tests

    func testProduct_Hashable_IdenticalProductsAreEqual() {
        // Given: Two products with identical properties
        let product1 = Product(id: "prod123", name: "Milk", category: "Dairy")
        let product2 = Product(id: "prod123", name: "Milk", category: "Dairy")

        // Then: Products with identical properties should be equal
        // Note: Product uses synthesized Equatable, comparing all stored properties
        XCTAssertEqual(product1, product2, "Products with identical properties should be equal")
    }

    func testProduct_Hashable_DifferentIDsProduceDifferentEquality() {
        // Given
        let product1 = Product(id: "prod123", name: "Milk", category: "Dairy")
        let product2 = Product(id: "prod456", name: "Milk", category: "Dairy")

        // When / Then
        XCTAssertNotEqual(product1, product2, "Products with different IDs should not be equal")
    }

    func testProduct_InSet_CanStoreUniqueProducts() {
        // Given
        let product1 = Product(id: "prod123", name: "Milk", category: "Dairy")
        let product2 = Product(id: "prod123", name: "Milk", category: "Dairy")
        let product3 = Product(id: "prod456", name: "Bread", category: "Bakery")

        // When
        var productSet: Set<Product> = []
        productSet.insert(product1)
        productSet.insert(product2) // Duplicate ID
        productSet.insert(product3)

        // Then
        XCTAssertEqual(productSet.count, 2, "Set should contain only unique products by ID")
    }

    // MARK: - Preview Helpers Tests

    func testProduct_PreviewHelper_ReturnsValidProduct() {
        // Given / When
        let product = Product.preview

        // Then
        XCTAssertEqual(product.id, "prod1")
        XCTAssertEqual(product.name, "Milk")
        XCTAssertTrue(product.aliases.contains("Whole Milk"))
        XCTAssertEqual(product.category, "Dairy")
        XCTAssertEqual(product.storeAisleMappings["store1"], "aisle3")
        XCTAssertEqual(product.storeAisleMappings["store2"], "aisle5")
    }

    func testProduct_PreviewListHelper_ReturnsValidList() {
        // Given / When
        let products = Product.previewList

        // Then
        XCTAssertEqual(products.count, 5)
        XCTAssertEqual(products[0].name, "Milk")
        XCTAssertEqual(products[1].name, "Eggs")
        XCTAssertEqual(products[2].name, "Bread")
        XCTAssertEqual(products[3].name, "Apples")
        XCTAssertEqual(products[4].name, "Chicken Breast")
    }

    func testProduct_PreviewListHelper_ContainsVariousCategories() {
        // Given / When
        let products = Product.previewList

        // Then
        let categories = Set(products.map { $0.category })
        XCTAssertTrue(categories.contains("Dairy"))
        XCTAssertTrue(categories.contains("Bakery"))
        XCTAssertTrue(categories.contains("Produce"))
        XCTAssertTrue(categories.contains("Meat"))
    }

    // MARK: - Edge Cases

    func testProduct_WithSpecialCharactersInName_NormalizesCorrectly() {
        // Given / When
        let product = Product(name: "Ben & Jerry's Ice Cream!", category: "Frozen")

        // Then
        XCTAssertEqual(product.normalizedName, "ben & jerry's ice cream!")
    }

    func testProduct_WithUnicodeCharacters_HandlesCorrectly() {
        // Given / When
        let product = Product(name: "Café Latte ☕", category: "Beverages")

        // Then
        XCTAssertEqual(product.normalizedName, "café latte ☕")
    }

    func testProduct_WithVeryLongAliasList_HandlesCorrectly() {
        // Given
        let manyAliases = (1...100).map { "Alias \($0)" }

        // When
        let product = Product(name: "Test Product", aliases: manyAliases, category: "Test")

        // Then
        XCTAssertEqual(product.aliases.count, 100)
        XCTAssertEqual(product.aliases.first, "Alias 1")
        XCTAssertEqual(product.aliases.last, "Alias 100")
    }

    func testProduct_WithVeryLongStoreMappings_HandlesCorrectly() {
        // Given
        var manyMappings: [String: String] = [:]
        for i in 1...100 {
            manyMappings["store\(i)"] = "aisle\(i)"
        }

        // When
        let product = Product(name: "Test Product", category: "Test", storeAisleMappings: manyMappings)

        // Then
        XCTAssertEqual(product.storeAisleMappings.count, 100)
        XCTAssertEqual(product.storeAisleMappings["store1"], "aisle1")
        XCTAssertEqual(product.storeAisleMappings["store100"], "aisle100")
    }
}
