import XCTest
@testable import GroceryApp

/// Shopping status decides who may touch the list. A status the app fails to
/// recognise silently degrades to `.idle`, which reads as "nobody is shopping" —
/// and that is exactly how two people end up editing the same list mid-trip.
final class ShoppingStatusTests: XCTestCase {

    func testAllStatusesParseFromTheirServerValues() {
        XCTAssertEqual(ShoppingStatus(rawValue: "IDLE"), .idle)
        XCTAssertEqual(ShoppingStatus(rawValue: "AT_STORE"), .atStore)
        XCTAssertEqual(ShoppingStatus(rawValue: "AD_HOC"), .adHoc)
    }

    func testUnknownStatusDoesNotParse() {
        // Callers fall back to .idle deliberately; the enum itself must report
        // that it did not recognise the value rather than guessing.
        XCTAssertNil(ShoppingStatus(rawValue: "SOMETHING_NEW"))
        XCTAssertNil(ShoppingStatus(rawValue: "at_store"))
    }

    func testRawValuesMatchTheSchema() {
        // These strings are the wire format. Changing one without changing the
        // Amplify enum silently breaks session detection for everyone.
        XCTAssertEqual(ShoppingStatus.idle.rawValue, "IDLE")
        XCTAssertEqual(ShoppingStatus.atStore.rawValue, "AT_STORE")
        XCTAssertEqual(ShoppingStatus.adHoc.rawValue, "AD_HOC")
    }

    func testItemStatusRawValuesMatchTheSchema() {
        XCTAssertEqual(GroceryItem.ItemStatus.active.rawValue, "ACTIVE")
        XCTAssertEqual(GroceryItem.ItemStatus.inCart.rawValue, "IN_CART")
        XCTAssertEqual(GroceryItem.ItemStatus.suggestion.rawValue, "SUGGESTION")
    }
}

/// The item defaults matter because they decide where an item shows up. A new
/// item defaulting to `adHoc = true` would vanish from the main list.
final class GroceryItemDefaultsTests: XCTestCase {

    func testNewItemDefaultsToTheMainList() {
        let item = GroceryItem(name: "Milk")

        XCTAssertEqual(item.status, .active)
        XCTAssertFalse(item.adHoc, "A new item belongs to the main list, not to an errand")
        XCTAssertFalse(item.adHocPulled)
        XCTAssertFalse(item.notesEphemeral, "Notes are durable unless explicitly marked trip-scoped")
    }

    func testNormalizedNameDefaultsFromTheName() {
        let item = GroceryItem(name: "  Bell Peppers  ")
        XCTAssertEqual(item.normalizedName, "bell peppers")
    }

    func testExplicitNormalizedNameWins() {
        let item = GroceryItem(name: "Carrots", normalizedName: "carrot")
        XCTAssertEqual(item.normalizedName, "carrot")
    }

    func testDecodingToleratesMissingNewFields() throws {
        // Rows written before adHoc/notesEphemeral existed must still decode —
        // production has hundreds of them.
        let json = """
        {
          "id": "1", "householdId": "hh", "name": "Milk", "normalizedName": "milk",
          "isCustom": false, "status": "ACTIVE", "addedBy": "me",
          "addedAt": "2026-01-01T00:00:00Z", "version": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(GroceryItem.self, from: Data(json.utf8))

        XCTAssertEqual(item.name, "Milk")
        XCTAssertFalse(item.adHoc)
        XCTAssertFalse(item.notesEphemeral)
        XCTAssertTrue(item.images.isEmpty)
    }
}
