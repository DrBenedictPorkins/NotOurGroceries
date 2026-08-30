import XCTest
@testable import GroceryApp

/// `addedAt` carries only one-second precision, so items added in the same second
/// tie. The list is fetched with an unordered scan, so ties come back in a
/// different order every refresh — which is why the list used to reshuffle itself
/// whenever the app was foregrounded. Every sort therefore needs a deterministic
/// tiebreaker.
///
/// Sorting used to reorder `items` in place, which meant one control silently
/// governed both the shopping list and the suggestions. It now lives in the
/// computed properties: `shoppingList` and `inCart` are always alphabetical —
/// the list is scanned for "is milk already on here?" far more often than it is
/// read top to bottom — and only `suggestions` follows `currentSort`.
@MainActor
final class SortStabilityTests: XCTestCase {

    private func sameSecondItems(status: GroceryItem.ItemStatus) -> [GroceryItem] {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            GroceryItem(id: "c", householdId: "hh", name: "Cherries", status: status, addedBy: "me", addedAt: t),
            GroceryItem(id: "a", householdId: "hh", name: "Apples",   status: status, addedBy: "me", addedAt: t),
            GroceryItem(id: "b", householdId: "hh", name: "Bananas",  status: status, addedBy: "me", addedAt: t)
        ]
    }

    // MARK: - Suggestions follow the chosen sort

    func testSuggestionsSortAlphabetically() {
        let vm = ShoppingListViewModel()
        vm.currentSort = .aToZ
        vm.items = sameSecondItems(status: .suggestion)

        XCTAssertEqual(vm.suggestions.map(\.name), ["Apples", "Bananas", "Cherries"])
    }

    func testSuggestionsSortReverseAlphabetically() {
        let vm = ShoppingListViewModel()
        vm.currentSort = .zToA
        vm.items = sameSecondItems(status: .suggestion)

        XCTAssertEqual(vm.suggestions.map(\.name), ["Cherries", "Bananas", "Apples"])
    }

    func testSuggestionsRecentFirstIsStableWhenTimestampsTie() {
        let vm = ShoppingListViewModel()
        vm.currentSort = .recentFirst

        vm.items = sameSecondItems(status: .suggestion)
        let first = vm.suggestions.map(\.id)

        // Simulate a refetch handing the same items back in a different order.
        vm.items = sameSecondItems(status: .suggestion).reversed()

        XCTAssertEqual(first, vm.suggestions.map(\.id),
                       "Same items, same timestamps: the order must not depend on how the server happened to return them")
    }

    func testSuggestionsWithIdenticalNamesStillSortDeterministically() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let vm = ShoppingListViewModel()
        vm.currentSort = .aToZ

        let dupes = [
            GroceryItem(id: "z", householdId: "hh", name: "Milk", status: .suggestion, addedBy: "me", addedAt: t),
            GroceryItem(id: "a", householdId: "hh", name: "Milk", status: .suggestion, addedBy: "me", addedAt: t)
        ]

        vm.items = dupes
        let first = vm.suggestions.map(\.id)

        vm.items = dupes.reversed()

        XCTAssertEqual(first, vm.suggestions.map(\.id),
                       "Two items with the same name and timestamp must still land in a fixed order")
    }

    // MARK: - The shopping list ignores it

    func testShoppingListIsAlwaysAlphabetical() {
        let vm = ShoppingListViewModel()
        vm.items = sameSecondItems(status: .active)

        XCTAssertEqual(vm.shoppingList.map(\.name), ["Apples", "Bananas", "Cherries"])
    }

    func testShoppingListIgnoresWhenThingsWereAdded() {
        let vm = ShoppingListViewModel()
        vm.items = [
            GroceryItem(id: "z", householdId: "hh", name: "Zucchini", status: .active, addedBy: "me",
                        addedAt: Date(timeIntervalSince1970: 9_000)),
            GroceryItem(id: "a", householdId: "hh", name: "Apples", status: .active, addedBy: "me",
                        addedAt: Date(timeIntervalSince1970: 1_000))
        ]

        // Newest first would put Zucchini on top. It does not.
        XCTAssertEqual(vm.shoppingList.map(\.name), ["Apples", "Zucchini"])
    }

    func testShoppingListOrderIgnoresTheSuggestionSort() {
        let vm = ShoppingListViewModel()
        vm.items = sameSecondItems(status: .active)

        // The order you added things in is information — "I just thought of
        // this" — and alphabetising a dozen visible rows throws it away. So the
        // control that reorders suggestions must not touch this list.
        vm.currentSort = .recentFirst
        let byRecent = vm.shoppingList.map(\.id)

        vm.currentSort = .aToZ
        XCTAssertEqual(vm.shoppingList.map(\.id), byRecent)

        vm.currentSort = .zToA
        XCTAssertEqual(vm.shoppingList.map(\.id), byRecent)
    }

    func testShoppingListIsStableWhenTimestampsTie() {
        let vm = ShoppingListViewModel()

        vm.items = sameSecondItems(status: .active)
        let first = vm.shoppingList.map(\.id)

        vm.items = sameSecondItems(status: .active).reversed()

        XCTAssertEqual(first, vm.shoppingList.map(\.id))
    }

    /// Crossing an item off must not make it jump to a different position in
    /// the section below.
    func testInCartMatchesTheListOrder() {
        let vm = ShoppingListViewModel()
        vm.items = sameSecondItems(status: .inCart)

        XCTAssertEqual(vm.inCart.map(\.name), ["Apples", "Bananas", "Cherries"])
    }

    // MARK: - The lists stay separate

    func testEachListOnlyContainsItsOwnStatus() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let vm = ShoppingListViewModel()
        vm.items = [
            GroceryItem(id: "1", householdId: "hh", name: "Active", status: .active, addedBy: "me", addedAt: t),
            GroceryItem(id: "2", householdId: "hh", name: "Cart",   status: .inCart, addedBy: "me", addedAt: t),
            GroceryItem(id: "3", householdId: "hh", name: "Sug",    status: .suggestion, addedBy: "me", addedAt: t)
        ]

        XCTAssertEqual(vm.shoppingList.map(\.id), ["1"])
        XCTAssertEqual(vm.inCart.map(\.id), ["2"])
        XCTAssertEqual(vm.suggestions.map(\.id), ["3"])
    }
}
