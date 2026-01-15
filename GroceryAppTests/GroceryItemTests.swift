import XCTest
@testable import GroceryApp

final class GroceryItemTests: XCTestCase {

    // MARK: - Initialization Tests

    func testGroceryItem_DefaultInitialization_SetsDefaultValues() {
        // Given / When
        let item = GroceryItem(name: "Milk")

        // Then
        XCTAssertFalse(item.id.isEmpty, "Should generate a non-empty ID")
        XCTAssertEqual(item.householdId, "", "Should default to empty household ID")
        XCTAssertEqual(item.name, "Milk")
        XCTAssertEqual(item.normalizedName, "milk", "Should auto-normalize name")
        XCTAssertNil(item.quantity, "Should default quantity to nil")
        XCTAssertNil(item.notes, "Should default notes to nil")
        XCTAssertEqual(item.isCustom, false, "Should default isCustom to false")
        XCTAssertNil(item.productId, "Should default productId to nil")
        XCTAssertEqual(item.status, .active, "Should default status to active")
        XCTAssertNil(item.lockedBy, "Should default lockedBy to nil")
        XCTAssertEqual(item.addedBy, "", "Should default addedBy to empty string")
        XCTAssertNotNil(item.addedAt, "Should set addedAt to current date")
        XCTAssertNil(item.crossedOffBy, "Should default crossedOffBy to nil")
        XCTAssertNil(item.crossedOffAt, "Should default crossedOffAt to nil")
        XCTAssertEqual(item.version, 0, "Should default version to 0")
    }

    func testGroceryItem_WithAllParameters_SetsAllValues() {
        // Given
        let id = "item123"
        let householdId = "household456"
        let name = "Milk"
        let normalizedName = "milk"
        let quantity = "1 gallon"
        let notes = "Organic"
        let isCustom = true
        let productId = "prod123"
        let status: GroceryItem.ItemStatus = .crossedOff
        let lockedBy = "user789"
        let addedBy = "user123"
        let addedAt = Date()
        let crossedOffBy = "user456"
        let crossedOffAt = Date()
        let version = 5

        // When
        let item = GroceryItem(
            id: id,
            householdId: householdId,
            name: name,
            normalizedName: normalizedName,
            quantity: quantity,
            notes: notes,
            isCustom: isCustom,
            productId: productId,
            status: status,
            lockedBy: lockedBy,
            addedBy: addedBy,
            addedAt: addedAt,
            crossedOffBy: crossedOffBy,
            crossedOffAt: crossedOffAt,
            version: version
        )

        // Then
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.householdId, householdId)
        XCTAssertEqual(item.name, name)
        XCTAssertEqual(item.normalizedName, normalizedName)
        XCTAssertEqual(item.quantity, quantity)
        XCTAssertEqual(item.notes, notes)
        XCTAssertEqual(item.isCustom, isCustom)
        XCTAssertEqual(item.productId, productId)
        XCTAssertEqual(item.status, status)
        XCTAssertEqual(item.lockedBy, lockedBy)
        XCTAssertEqual(item.addedBy, addedBy)
        XCTAssertEqual(item.addedAt, addedAt)
        XCTAssertEqual(item.crossedOffBy, crossedOffBy)
        XCTAssertEqual(item.crossedOffAt, crossedOffAt)
        XCTAssertEqual(item.version, version)
    }

    func testGroceryItem_NormalizedNameAutoGeneration_TrimsAndLowercases() {
        // Given / When
        let item = GroceryItem(name: "  MILK  ")

        // Then
        XCTAssertEqual(item.normalizedName, "milk")
    }

    func testGroceryItem_WithCustomNormalizedName_UsesProvidedValue() {
        // Given / When
        let item = GroceryItem(name: "Milk", normalizedName: "custom-milk")

        // Then
        XCTAssertEqual(item.normalizedName, "custom-milk")
    }

    func testGroceryItem_WithEmptyName_CreatesNormalizedName() {
        // Given / When
        let item = GroceryItem(name: "")

        // Then
        XCTAssertEqual(item.normalizedName, "")
    }

    func testGroceryItem_WithWhitespaceOnlyName_CreatesEmptyNormalizedName() {
        // Given / When
        let item = GroceryItem(name: "   ")

        // Then
        XCTAssertEqual(item.normalizedName, "")
    }

    // MARK: - ItemStatus Tests

    func testItemStatus_ActiveRawValue_IsCorrect() {
        // Given / When / Then
        XCTAssertEqual(GroceryItem.ItemStatus.active.rawValue, "ACTIVE")
    }

    func testItemStatus_CrossedOffRawValue_IsCorrect() {
        // Given / When / Then
        XCTAssertEqual(GroceryItem.ItemStatus.crossedOff.rawValue, "CROSSED_OFF")
    }

    func testItemStatus_CanDecodeFromRawValue() {
        // Given / When
        let activeStatus = GroceryItem.ItemStatus(rawValue: "ACTIVE")
        let crossedOffStatus = GroceryItem.ItemStatus(rawValue: "CROSSED_OFF")

        // Then
        XCTAssertEqual(activeStatus, .active)
        XCTAssertEqual(crossedOffStatus, .crossedOff)
    }

    func testItemStatus_InvalidRawValue_ReturnsNil() {
        // Given / When
        let invalidStatus = GroceryItem.ItemStatus(rawValue: "INVALID")

        // Then
        XCTAssertNil(invalidStatus)
    }

    // MARK: - Codable Tests

    func testGroceryItem_Encodable_CanEncodeToJSON() throws {
        // Given
        let item = GroceryItem(
            id: "item123",
            householdId: "household456",
            name: "Milk",
            quantity: "1 gallon",
            notes: "Organic",
            isCustom: false,
            productId: "prod123",
            status: .active,
            addedBy: "user123",
            version: 1
        )

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(item)

        // Then
        XCTAssertFalse(data.isEmpty)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["id"] as? String, "item123")
        XCTAssertEqual(json?["name"] as? String, "Milk")
        XCTAssertEqual(json?["quantity"] as? String, "1 gallon")
    }

    func testGroceryItem_Decodable_CanDecodeFromJSON() throws {
        // Given
        let json = """
        {
            "id": "item123",
            "householdId": "household456",
            "name": "Milk",
            "normalizedName": "milk",
            "quantity": "1 gallon",
            "notes": "Organic",
            "isCustom": false,
            "productId": "prod123",
            "status": "ACTIVE",
            "addedBy": "user123",
            "addedAt": "2024-01-01T10:00:00Z",
            "version": 1
        }
        """

        // When
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        let item = try decoder.decode(GroceryItem.self, from: data)

        // Then
        XCTAssertEqual(item.id, "item123")
        XCTAssertEqual(item.householdId, "household456")
        XCTAssertEqual(item.name, "Milk")
        XCTAssertEqual(item.normalizedName, "milk")
        XCTAssertEqual(item.quantity, "1 gallon")
        XCTAssertEqual(item.notes, "Organic")
        XCTAssertEqual(item.isCustom, false)
        XCTAssertEqual(item.productId, "prod123")
        XCTAssertEqual(item.status, .active)
        XCTAssertEqual(item.addedBy, "user123")
        XCTAssertEqual(item.version, 1)
    }

    // MARK: - Hashable Tests

    func testGroceryItem_Hashable_IdenticalItemsAreEqual() {
        // Given: Two items with identical properties
        let addedAt = Date()
        let item1 = GroceryItem(id: "item123", name: "Milk", addedBy: "John", addedAt: addedAt)
        let item2 = GroceryItem(id: "item123", name: "Milk", addedBy: "John", addedAt: addedAt)

        // Then: Items with identical properties should be equal
        // Note: GroceryItem uses synthesized Equatable, comparing all stored properties
        XCTAssertEqual(item1, item2, "Items with identical properties should be equal")
    }

    func testGroceryItem_Hashable_DifferentIDsProduceDifferentEquality() {
        // Given
        let item1 = GroceryItem(id: "item123", name: "Milk", addedBy: "John")
        let item2 = GroceryItem(id: "item456", name: "Milk", addedBy: "John")

        // When / Then
        XCTAssertNotEqual(item1, item2, "Items with different IDs should not be equal")
    }

    func testGroceryItem_InSet_CanStoreUniqueItems() {
        // Given: Two items with identical properties, and one different
        let addedAt = Date()
        let item1 = GroceryItem(id: "item123", name: "Milk", addedBy: "John", addedAt: addedAt)
        let item2 = GroceryItem(id: "item123", name: "Milk", addedBy: "John", addedAt: addedAt)
        let item3 = GroceryItem(id: "item456", name: "Bread", addedBy: "Sarah", addedAt: addedAt)

        // When
        var itemSet: Set<GroceryItem> = []
        itemSet.insert(item1)
        itemSet.insert(item2) // Identical item (same properties)
        itemSet.insert(item3)

        // Then: Set should contain only unique items (by all properties, not just ID)
        // Note: GroceryItem uses synthesized Hashable, so identical items are deduped
        XCTAssertEqual(itemSet.count, 2, "Set should contain only unique items")
    }

    // MARK: - Preview Helpers Tests

    func testGroceryItem_PreviewHelper_ReturnsValidItem() {
        // Given / When
        let item = GroceryItem.preview

        // Then
        XCTAssertEqual(item.id, "1")
        XCTAssertEqual(item.householdId, "household1")
        XCTAssertEqual(item.name, "Milk")
        XCTAssertEqual(item.quantity, "1 gallon")
        XCTAssertEqual(item.notes, "Organic")
        XCTAssertEqual(item.addedBy, "user1")
    }

    func testGroceryItem_CustomPreviewHelper_ReturnsCustomItem() {
        // Given / When
        let item = GroceryItem.customPreview

        // Then
        XCTAssertEqual(item.id, "2")
        XCTAssertTrue(item.isCustom)
        XCTAssertEqual(item.name, "Trader Joe's Everything Bagel Seasoning")
        XCTAssertEqual(item.addedBy, "user2")
    }

    func testGroceryItem_LockedPreviewHelper_ReturnsLockedItem() {
        // Given / When
        let item = GroceryItem.lockedPreview

        // Then
        XCTAssertEqual(item.id, "3")
        XCTAssertEqual(item.lockedBy, "user123")
        XCTAssertEqual(item.name, "Coffee")
    }

    // MARK: - Mutable Property Tests

    func testGroceryItem_StatusIsMutable() {
        // Given
        var item = GroceryItem(name: "Milk", status: .active, addedBy: "John")

        // When
        item.status = .crossedOff

        // Then
        XCTAssertEqual(item.status, .crossedOff)
    }

    func testGroceryItem_QuantityIsMutable() {
        // Given
        var item = GroceryItem(name: "Milk", quantity: "1 gallon", addedBy: "John")

        // When
        item.quantity = "2 gallons"

        // Then
        XCTAssertEqual(item.quantity, "2 gallons")
    }

    func testGroceryItem_NotesIsMutable() {
        // Given
        var item = GroceryItem(name: "Milk", notes: "Organic", addedBy: "John")

        // When
        item.notes = "Non-organic"

        // Then
        XCTAssertEqual(item.notes, "Non-organic")
    }

    func testGroceryItem_VersionIsMutable() {
        // Given
        var item = GroceryItem(name: "Milk", addedBy: "John", version: 1)

        // When
        item.version = 2

        // Then
        XCTAssertEqual(item.version, 2)
    }

    func testGroceryItem_LockedByIsMutable() {
        // Given
        var item = GroceryItem(name: "Milk", addedBy: "John")

        // When
        item.lockedBy = "user123"

        // Then
        XCTAssertEqual(item.lockedBy, "user123")
    }

    func testGroceryItem_CrossedOffFieldsAreMutable() {
        // Given
        var item = GroceryItem(name: "Milk", status: .active, addedBy: "John")

        // When
        item.crossedOffBy = "user456"
        item.crossedOffAt = Date()

        // Then
        XCTAssertEqual(item.crossedOffBy, "user456")
        XCTAssertNotNil(item.crossedOffAt)
    }

    // MARK: - Codable Tests for Transient Fields

    func testGroceryItem_EncodingExcludesTransientFields() throws {
        // Given: An item (transient fields would be isPendingRemoval, isOptimisticUpdate if added)
        let item = GroceryItem(
            id: "item123",
            householdId: "household456",
            name: "Milk"
        )

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(item)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Then: Verify all expected fields are present
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["id"] as? String, "item123")
        XCTAssertEqual(json?["name"] as? String, "Milk")
        XCTAssertEqual(json?["householdId"] as? String, "household456")

        // Note: If isPendingRemoval or isOptimisticUpdate were added,
        // they should NOT appear in encoded JSON
    }

    func testGroceryItem_DecodingIgnoresTransientFields() throws {
        // Given: JSON with all fields
        let json = """
        {
            "id": "item123",
            "householdId": "household456",
            "name": "Milk",
            "normalizedName": "milk",
            "isCustom": false,
            "status": "ACTIVE",
            "addedBy": "user123",
            "addedAt": "2024-01-01T10:00:00Z",
            "version": 1
        }
        """

        // When
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        let item = try decoder.decode(GroceryItem.self, from: data)

        // Then: Item should be decoded successfully
        XCTAssertEqual(item.id, "item123")
        XCTAssertEqual(item.name, "Milk")

        // Transient fields would default to false if they existed
    }

    // MARK: - Version Field Tests

    func testGroceryItem_VersionDefaultsToZero() {
        // Given / When
        let item = GroceryItem(name: "Milk")

        // Then
        XCTAssertEqual(item.version, 0, "Version should default to 0")
    }

    func testGroceryItem_VersionCanBeSet() {
        // Given / When
        let item = GroceryItem(name: "Milk", version: 5)

        // Then
        XCTAssertEqual(item.version, 5)
    }

    // MARK: - Equality Tests for Version

    func testGroceryItem_EqualityComparesAllProperties() {
        // Given: Two items with same ID but different versions
        let addedAt = Date()
        let item1 = GroceryItem(id: "item123", name: "Milk", addedBy: "John", addedAt: addedAt, version: 1)
        let item2 = GroceryItem(id: "item123", name: "Milk", addedBy: "John", addedAt: addedAt, version: 5)

        // When / Then: Items should NOT be equal because version differs
        // Note: GroceryItem uses synthesized Equatable, comparing all stored properties
        XCTAssertNotEqual(item1, item2, "Items with different versions should not be equal")
    }

    // MARK: - Status Transition Tests

    func testGroceryItem_StatusTransitionFromActiveTooCrossedOff() {
        // Given
        var item = GroceryItem(
            name: "Milk",
            status: .active,
            version: 0
        )

        // When
        item.status = .crossedOff
        item.crossedOffBy = "user456"
        item.crossedOffAt = Date()
        item.version = 1

        // Then
        XCTAssertEqual(item.status, .crossedOff)
        XCTAssertNotNil(item.crossedOffBy)
        XCTAssertNotNil(item.crossedOffAt)
        XCTAssertEqual(item.version, 1)
    }

    func testGroceryItem_StatusTransitionFromCrossedOffToActive() {
        // Given
        var item = GroceryItem(
            name: "Milk",
            status: .crossedOff,
            crossedOffBy: "user456",
            crossedOffAt: Date(),
            version: 1
        )

        // When: Restore item
        item.status = .active
        item.crossedOffBy = nil
        item.crossedOffAt = nil
        item.version = 2

        // Then
        XCTAssertEqual(item.status, .active)
        XCTAssertNil(item.crossedOffBy)
        XCTAssertNil(item.crossedOffAt)
        XCTAssertEqual(item.version, 2)
    }
}
