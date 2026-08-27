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
        adHoc: Bool = false,
        pulled: Bool = false,
        addedAt: Date = Date()
    ) -> GroceryItem {
        GroceryItem(
            id: "\(name)-\(adHoc)-\(status.rawValue)",
            householdId: "hh",
            name: name,
            adHoc: adHoc,
            adHocPulled: pulled,
            status: status,
            addedBy: "me",
            addedAt: addedAt
        )
    }

    // MARK: - Main list must never show errand items

    func testShoppingListExcludesAdHocItems() {
        let vm = ShoppingListViewModel()
        vm.items = [
            item("Milk"),
            item("Tortillas", adHoc: true),
            item("Eggs")
        ]

        let names = vm.shoppingList.map(\.name).sorted()
        XCTAssertEqual(names, ["Eggs", "Milk"],
                       "An errand item must not appear on the main list — that is the whole point of Quick Trip")
    }

    func testInCartExcludesAdHocItems() {
        let vm = ShoppingListViewModel()
        vm.items = [
            item("Milk", status: .inCart),
            item("Tortillas", status: .inCart, adHoc: true)
        ]

        XCTAssertEqual(vm.inCart.map(\.name), ["Milk"])
    }

    func testAdHocListShowsOnlyErrandActiveItems() {
        let vm = ShoppingListViewModel()
        vm.items = [
            item("Milk"),
            item("Tortillas", adHoc: true),
            item("Beans", status: .inCart, adHoc: true),
            item("Rice", status: .suggestion)
        ]

        XCTAssertEqual(vm.adHocList.map(\.name), ["Tortillas"])
        XCTAssertEqual(vm.adHocInCart.map(\.name), ["Beans"])
    }

    func testSuggestionsAreSharedAcrossModes() {
        // Suggestions are the household's memory and are deliberately not
        // partitioned by errand — you can pull one onto any kind of trip.
        let vm = ShoppingListViewModel()
        vm.items = [
            item("Milk", status: .suggestion),
            item("Salsa", status: .suggestion, adHoc: true)
        ]

        XCTAssertEqual(vm.suggestions.count, 2)
    }

    func testEveryItemLandsInExactlyOnePartition() {
        let vm = ShoppingListViewModel()
        vm.items = [
            item("A"),
            item("B", status: .inCart),
            item("C", status: .suggestion),
            item("D", adHoc: true),
            item("E", status: .inCart, adHoc: true)
        ]

        // Suggestions overlap by design; the other four must be disjoint and total.
        let partitioned = vm.shoppingList.count + vm.inCart.count
            + vm.adHocList.count + vm.adHocInCart.count + vm.suggestions.count
        XCTAssertEqual(partitioned, vm.items.count,
                       "An item in no partition is invisible to the user and effectively lost")
    }
}
