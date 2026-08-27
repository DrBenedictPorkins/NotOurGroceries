import XCTest
@testable import GroceryApp

/// `addedAt` carries only one-second precision, so items added in the same second
/// tie. The list is fetched with an unordered scan, so ties come back in a
/// different order every refresh — which is why the list used to reshuffle itself
/// whenever the app was foregrounded. Every sort therefore needs a deterministic
/// tiebreaker.
@MainActor
final class SortStabilityTests: XCTestCase {

    private func sameSecondItems() -> [GroceryItem] {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            GroceryItem(id: "c", householdId: "hh", name: "Cherries", addedBy: "me", addedAt: t),
            GroceryItem(id: "a", householdId: "hh", name: "Apples",   addedBy: "me", addedAt: t),
            GroceryItem(id: "b", householdId: "hh", name: "Bananas",  addedBy: "me", addedAt: t)
        ]
    }

    func testRecentFirstIsStableWhenTimestampsTie() {
        let vm = ShoppingListViewModel()
        vm.currentSort = .recentFirst

        vm.items = sameSecondItems()
        vm.applySorting()
        let first = vm.items.map(\.id)

        // Simulate a refetch handing the same items back in a different order.
        vm.items = sameSecondItems().reversed()
        vm.applySorting()
        let second = vm.items.map(\.id)

        XCTAssertEqual(first, second,
                       "Same items, same timestamps: the order must not depend on how the server happened to return them")
    }

    func testAlphabeticalSortsByName() {
        let vm = ShoppingListViewModel()
        vm.currentSort = .aToZ
        vm.items = sameSecondItems()
        vm.applySorting()

        XCTAssertEqual(vm.items.map(\.name), ["Apples", "Bananas", "Cherries"])
    }

    func testReverseAlphabetical() {
        let vm = ShoppingListViewModel()
        vm.currentSort = .zToA
        vm.items = sameSecondItems()
        vm.applySorting()

        XCTAssertEqual(vm.items.map(\.name), ["Cherries", "Bananas", "Apples"])
    }

    func testIdenticalNamesStillSortDeterministically() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let vm = ShoppingListViewModel()
        vm.currentSort = .aToZ

        let dupes = [
            GroceryItem(id: "z", householdId: "hh", name: "Milk", addedBy: "me", addedAt: t),
            GroceryItem(id: "a", householdId: "hh", name: "Milk", addedBy: "me", addedAt: t)
        ]

        vm.items = dupes
        vm.applySorting()
        let first = vm.items.map(\.id)

        vm.items = dupes.reversed()
        vm.applySorting()

        XCTAssertEqual(first, vm.items.map(\.id),
                       "Two items with the same name and timestamp must still land in a fixed order")
    }

    func testRecentFirstPutsNewerFirstWhenTimestampsDiffer() {
        let vm = ShoppingListViewModel()
        vm.currentSort = .recentFirst
        vm.items = [
            GroceryItem(id: "old", householdId: "hh", name: "Old", addedBy: "me",
                        addedAt: Date(timeIntervalSince1970: 1_000)),
            GroceryItem(id: "new", householdId: "hh", name: "New", addedBy: "me",
                        addedAt: Date(timeIntervalSince1970: 9_000))
        ]
        vm.applySorting()

        XCTAssertEqual(vm.items.first?.id, "new")
    }
}
