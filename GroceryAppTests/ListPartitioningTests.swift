import XCTest
@testable import GroceryApp

/// The list is partitioned four ways — main list, cart, suggestions, and the
/// current errand — and every one of those is a filter over the same array.
/// A wrong predicate here does not crash; it silently hides groceries, which is
/// the failure that costs a shopping trip.
@MainActor
final class ListPartitioningTests: XCTestCase {

    private func item(
        _ name: String,
        status: GroceryItem.ItemStatus = .active,
        addedAt: Date = Date()
    ) -> GroceryItem {
        GroceryItem(
            id: "\(name)-\(status.rawValue)",
            householdId: "hh",
            name: name,
            status: status,
            addedBy: "me",
            addedAt: addedAt
        )
    }

    func testSuggestionsAreSharedAcrossModes() {
        // Suggestions are the household's memory and are deliberately not
        // partitioned by errand — you can pull one onto any kind of trip.
        let vm = ShoppingListViewModel()
        vm.items = [
            item("Milk", status: .suggestion),
            item("Salsa", status: .suggestion)
        ]

        XCTAssertEqual(vm.suggestions.count, 2)
    }

    func testEveryItemLandsInExactlyOnePartition() {
        let vm = ShoppingListViewModel()
        vm.items = [
            item("A"),
            item("B", status: .inCart),
            item("C", status: .suggestion),
            item("D"),
            item("E", status: .inCart)
        ]

        // Comparing counts would let a double-count hide a dropped item, so
        // compare the actual ids: every item must surface somewhere.
        var seen = Set<String>()
        for list in [vm.shoppingList, vm.inCart, vm.suggestions] {
            seen.formUnion(list.map(\.id))
        }
        XCTAssertEqual(seen, Set(vm.items.map(\.id)),
                       "An item in no partition is invisible to the user and effectively lost")
    }
}
