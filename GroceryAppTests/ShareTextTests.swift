import XCTest
@testable import GroceryApp

/// Shared text lands in Messages, WhatsApp and Mail, none of which render
/// Markdown and all of which set proportional type. These tests pin the two
/// things that would break it there — stray syntax and tab columns — plus the
/// content rules that stop a shared list from misleading whoever receives it.
final class ShareTextTests: XCTestCase {

    private func item(_ name: String, quantity: String? = nil) -> GroceryItem {
        GroceryItem(
            id: UUID().uuidString,
            householdId: "household-1",
            name: name,
            quantity: quantity,
            status: .active
        )
    }

    // MARK: - Portability

    func testUsesNoMarkdownOrTabs() {
        let text = ShareText.shoppingList(
            active: [item("Milk", quantity: "1 gal"), item("Eggs")],
            inCart: [item("Butter")],
            storeName: "Wegmans"
        )

        XCTAssertFalse(text.contains("\t"), "tab stops land ragged in proportional type")
        XCTAssertFalse(text.contains("**"), "arrives as literal asterisks in Messages")
        XCTAssertFalse(text.contains("|"), "table pipes arrive as pipes")
        XCTAssertFalse(text.contains("#"), "heading marks arrive as hashes")
    }

    // MARK: - Shopping list

    func testListsEveryActiveItemOnItsOwnLine() {
        let text = ShareText.shoppingList(
            active: [item("Milk"), item("Eggs"), item("Bread")],
            inCart: [],
            storeName: nil
        )

        let bullets = text.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(bullets, ["- Milk", "- Eggs", "- Bread"])
    }

    func testKeepsTheOrderItWasGiven() {
        let text = ShareText.shoppingList(
            active: [item("Zucchini"), item("Apples")],
            inCart: [],
            storeName: nil
        )

        XCTAssertLessThan(text.range(of: "Zucchini")!.lowerBound,
                          text.range(of: "Apples")!.lowerBound,
                          "the list is shared as shown, not re-sorted")
    }

    /// Amounts are not shared, because they are no longer captured. The parser
    /// strips "2 lbs" off the name and discards it — a shopping list says what to
    /// buy, and the shopper decides what size packet when they are at the shelf.
    func testAmountsNeverAppearInSharedText() {
        let text = ShareText.shoppingList(
            active: [item("Milk", quantity: "1 gal"), item("Eggs")],
            inCart: [],
            storeName: nil
        )

        XCTAssertTrue(text.contains("- Milk"))
        XCTAssertTrue(text.contains("- Eggs"))
        XCTAssertFalse(text.contains("1 gal"),
                       "a stale quantity on an old row must not leak into the share text")
        XCTAssertFalse(text.contains("()"), "and no empty brackets either")
    }

    func testCountsOnlyWhatIsStillToBuy() {
        let text = ShareText.shoppingList(
            active: [item("Milk"), item("Eggs")],
            inCart: [item("Butter"), item("Jam"), item("Tea")],
            storeName: nil
        )

        XCTAssertTrue(text.contains("2 items"),
                      "the header answers 'what do I still need', not 'how big was the list'")
    }

    func testSingularItemCount() {
        let text = ShareText.shoppingList(active: [item("Milk")], inCart: [], storeName: nil)
        XCTAssertTrue(text.contains("1 item"))
        XCTAssertFalse(text.contains("1 items"))
    }

    func testShowsWhatIsAlreadyInTheCart() {
        let text = ShareText.shoppingList(
            active: [item("Milk")],
            inCart: [item("Butter")],
            storeName: nil
        )

        // Hiding this mid-trip is how you get a second carton of milk.
        XCTAssertTrue(text.contains("Already in the cart"))
        XCTAssertTrue(text.contains("- Butter"))
    }

    func testOmitsTheCartSectionWhenNothingIsInIt() {
        let text = ShareText.shoppingList(active: [item("Milk")], inCart: [], storeName: nil)
        XCTAssertFalse(text.contains("Already in the cart"))
    }

    func testIncludesStoreOnlyWhenThereIsOne() {
        let named = ShareText.shoppingList(active: [item("Milk")], inCart: [], storeName: "Wegmans")
        XCTAssertTrue(named.contains("Wegmans"))

        let unnamed = ShareText.shoppingList(active: [item("Milk")], inCart: [], storeName: nil)
        XCTAssertFalse(unnamed.contains(" · "), "no store means no empty separator")

        let blank = ShareText.shoppingList(active: [item("Milk")], inCart: [], storeName: "")
        XCTAssertFalse(blank.contains(" · "))
    }

    func testAnEmptyListStillSaysWhatItIs() {
        let text = ShareText.shoppingList(active: [], inCart: [], storeName: nil)

        XCTAssertTrue(text.contains("Shopping list"))
        XCTAssertTrue(text.contains("0 items"))
        XCTAssertFalse(text.hasSuffix("\n\n"), "no dangling blank section")
    }

    // MARK: - Quick trip

    func testQuickTripSeparatesWhatIsLeftFromWhatIsGot() {
        let lines = [
            QuickListStore.Line(name: "Milk", checked: false),
            QuickListStore.Line(name: "Bread", checked: true)
        ]

        let text = ShareText.quickTrip(lines: lines)

        XCTAssertTrue(text.contains("1 item"), "counts only what is still to get")
        XCTAssertTrue(text.contains("Got already"))
        XCTAssertLessThan(text.range(of: "Milk")!.lowerBound,
                          text.range(of: "Got already")!.lowerBound,
                          "what you still need comes first")
    }

    func testQuickTripOmitsTheGotSectionWhenNothingIsTicked() {
        let lines = [QuickListStore.Line(name: "Milk", checked: false)]
        XCTAssertFalse(ShareText.quickTrip(lines: lines).contains("Got already"))
    }

    func testQuickTripWithEverythingTickedReportsNothingLeft() {
        let lines = [
            QuickListStore.Line(name: "Milk", checked: true),
            QuickListStore.Line(name: "Bread", checked: true)
        ]

        let text = ShareText.quickTrip(lines: lines)
        XCTAssertTrue(text.contains("0 items"))
        XCTAssertTrue(text.contains("Got already"))
    }
}
