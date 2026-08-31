import XCTest
@testable import GroceryApp

/// Aisle ids are storage keys, and they leaked onto screen — the batch mapper
/// offered "standard-household" as if that were somewhere you could walk to.
/// These tests pin the rule that an id never reaches the user unresolved.
final class AisleNamingTests: XCTestCase {

    private func aisle(id: String, number: String = "", name: String) -> StoreAisle {
        StoreAisle(id: id, number: number, name: name, displayOrder: 0, description: "")
    }

    // MARK: - The store's own layout wins

    func testUsesTheStoresOwnNameForTheAisle() {
        let layout = [aisle(id: "a1", number: "7", name: "Baking")]

        XCTAssertEqual(AisleNaming.displayName(for: "a1", in: layout), "Aisle 7 — Baking")
    }

    func testNamesAnUnnumberedSectionPlainly() {
        let layout = [aisle(id: "standard-dairy", name: "Dairy & Eggs")]

        XCTAssertEqual(AisleNaming.displayName(for: "standard-dairy", in: layout), "Dairy & Eggs")
    }

    func testMatchesOnIdNameOrNumber() {
        // Which of the three got written depends on the build that saved the
        // mapping, so all three have to resolve.
        let layout = [aisle(id: "a1", number: "7", name: "Baking")]

        XCTAssertEqual(AisleNaming.displayName(for: "a1", in: layout), "Aisle 7 — Baking")
        XCTAssertEqual(AisleNaming.displayName(for: "Baking", in: layout), "Aisle 7 — Baking")
        XCTAssertEqual(AisleNaming.displayName(for: "7", in: layout), "Aisle 7 — Baking")
    }

    func testMatchingIgnoresCaseAndSurroundingSpace() {
        let layout = [aisle(id: "standard-dairy", name: "Dairy & Eggs")]

        XCTAssertEqual(AisleNaming.displayName(for: "  STANDARD-DAIRY ", in: layout), "Dairy & Eggs")
        XCTAssertEqual(AisleNaming.displayName(for: "dairy & eggs", in: layout), "Dairy & Eggs")
    }

    func testANonNumericAisleNumberIsNotCalledAnAisleNumber() {
        // Some stores label sections "A", "B", "Back wall".
        let layout = [aisle(id: "a1", number: "B", name: "Baking")]

        XCTAssertEqual(AisleNaming.displayName(for: "a1", in: layout), "B — Baking")
    }

    // MARK: - Falling back

    func testABareNumberIsAnAisleNumber() {
        XCTAssertEqual(AisleNaming.displayName(for: "12", in: []), "Aisle 12")
    }

    func testResolvesStandardIdsWithoutALayout() {
        // A store that has not been backfilled yet still has mappings pointing
        // at standard ids, and they have to read as words.
        XCTAssertEqual(AisleNaming.displayName(for: "standard-frozen", in: []), "Frozen")
        XCTAssertEqual(AisleNaming.displayName(for: "standard-household", in: []), "Household")
        XCTAssertEqual(AisleNaming.displayName(for: "standard-pharmacy", in: []), "Pharmacy & Health")
    }

    func testTidiesAnUnknownStandardStyleId() {
        // Shape of one of ours but not one of ours — a model made it up, or it
        // predates a rename. Still better as words than as a slug.
        XCTAssertEqual(AisleNaming.displayName(for: "standard-pet-food", in: []), "Pet Food")
    }

    func testAnUnrecognisedIdIsShownAsItIs() {
        // Hiding it behind "Unknown" loses the only clue about what went wrong.
        XCTAssertEqual(AisleNaming.displayName(for: "Back cooler", in: []), "Back cooler")
    }

    func testAnEmptyIdIsNamedNotBlank() {
        XCTAssertEqual(AisleNaming.displayName(for: "", in: []), "Unsorted")
        XCTAssertEqual(AisleNaming.displayName(for: "   ", in: []), "Unsorted")
    }

    func testAnAisleWithNeitherNameNorNumberIsNamedNotBlank() {
        let layout = [aisle(id: "a1", name: "")]

        XCTAssertEqual(AisleNaming.displayName(for: "a1", in: layout), "Unsorted")
    }

    // MARK: - Headers stay short

    func testAContentsBlobIsNotAHeader() {
        // A directory scan fills `name` with a sample of what the sign listed.
        // Joining that to the number gave three-line section headers in At Store.
        let layout = [aisle(id: "a15", number: "15",
                            name: "sanitary products, sports braces, sports nutrition")]

        XCTAssertEqual(AisleNaming.displayName(for: "a15", in: layout), "Aisle 15")
    }

    func testAShortNameIsStillKept() {
        let layout = [aisle(id: "a7", number: "7", name: "Baking")]

        XCTAssertEqual(AisleNaming.displayName(for: "a7", in: layout), "Aisle 7 — Baking")
    }

    func testAnUnnumberedContentsBlobIsCutAtTheFirstItem() {
        // Nothing to fall back on, so the name has to serve — but it still must
        // not run on for three lines.
        let layout = [aisle(id: "x", name: "syrup, tea bags, chocolate syrup, jam")]

        XCTAssertEqual(AisleNaming.displayName(for: "x", in: layout), "syrup")
    }

    func testAVeryLongSingleWordIsTruncated() {
        let layout = [aisle(id: "x", name: String(repeating: "a", count: 40))]

        let name = AisleNaming.displayName(for: "x", in: layout)
        XCTAssertTrue(name.hasSuffix("…"))
        XCTAssertLessThanOrEqual(name.count, 21)
    }

    func testANumberedAisleWithNoNameIsJustTheAisle() {
        let layout = [aisle(id: "a3", number: "3", name: "")]

        XCTAssertEqual(AisleNaming.displayName(for: "a3", in: layout), "Aisle 3")
    }

    // MARK: - Header form

    func testHeaderNameIsTheSameNameUpperCased() {
        let layout = [aisle(id: "standard-dairy", name: "Dairy & Eggs")]

        XCTAssertEqual(AisleNaming.headerName(for: "standard-dairy", in: layout), "DAIRY & EGGS")
    }

    func testAWordUsedAsAnAisleNumberIsNotCalledAnAisle() {
        // Observed as "Aisle Dairy" in Aisle Management: the local copy of this
        // logic prefixed "Aisle" onto any number, including one that is a word.
        let layout = [aisle(id: "d", number: "Dairy", name: "")]

        XCTAssertEqual(AisleNaming.displayName(for: "d", in: layout), "Dairy")
    }

    func testAWordNumberWithANameReadsAsBoth() {
        let layout = [aisle(id: "d", number: "Back Wall", name: "Dairy")]

        XCTAssertEqual(AisleNaming.displayName(for: "d", in: layout), "Back Wall — Dairy")
    }

    // MARK: - The standard set

    func testStandardIdsAreUnique() {
        let ids = StoreService.namedDepartments.map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count,
                       "a duplicate id would make backfill and lookup disagree")
    }

    func testEveryStandardSectionResolvesToItsOwnName() {
        for section in StoreService.namedDepartments {
            XCTAssertEqual(AisleNaming.displayName(for: section.id, in: []), section.name,
                           "\(section.id) does not resolve to its name")
        }
    }

    func testMedicineHasSomewhereToGoThatIsNotHousehold() {
        // Unisom was being filed under Household, next to the bin bags.
        let ids = Set(StoreService.namedDepartments.map(\.id))

        XCTAssertTrue(ids.contains("standard-pharmacy"))
        XCTAssertTrue(ids.contains("standard-personal"))

        let household = StoreService.namedDepartments.first { $0.id == "standard-household" }
        XCTAssertNotNil(household)
        XCTAssertFalse((household!.description ?? "").lowercased().contains("toiletries"),
                       "toiletries belong to Personal Care now")
    }

    // MARK: - Walk order

    /// The default is the walk most shops present: in past the produce, through
    /// the numbered aisles, out past the freezers. It is only a default — some
    /// people deliberately take produce last so it is not crushed under tins —
    /// which is why Aisle Management can drag it into any order. These tests pin
    /// the bands, not anybody's preference.
    private func order(_ id: String) -> Int {
        StoreService.namedDepartments.first { $0.id == id }?.displayOrder ?? .max
    }

    func testPerimeterSortsBeforeAStoresNumberedAisles() {
        // Scanned aisles are written with displayOrder 0…n, so the perimeter has
        // to be negative to land ahead of them.
        for id in ["standard-produce", "standard-bakery", "standard-deli",
                   "standard-meat", "standard-seafood", "standard-dairy"] {
            XCTAssertLessThan(order(id), 0, "\(id) should come before aisle 1")
        }
    }

    func testCentreStoreSortsAfterTheNumberedAisles() {
        // In a numbered store these are not places — pasta *is* one of the
        // aisles — so they only hold what inference could not pin down. Putting
        // them first would send someone looking for shelves that do not exist.
        for id in ["standard-pantry", "standard-canned", "standard-snacks",
                   "standard-household", "standard-pharmacy"] {
            XCTAssertGreaterThan(order(id), 100, "\(id) should come after the numbered aisles")
        }
    }

    func testProduceIsFirstAndFrozenIsLast() {
        let orders = StoreService.namedDepartments.map(\.displayOrder)

        XCTAssertEqual(order("standard-produce"), orders.min())
        XCTAssertEqual(order("standard-frozen"), orders.max(), "frozen melts")
    }

    func testStandardSectionsHaveDistinctDisplayOrders() {
        let orders = StoreService.namedDepartments.map(\.displayOrder)

        XCTAssertEqual(Set(orders).count, orders.count,
                       "equal orders sort unstably, so the walk order changes between launches")
    }

    func testStandardSectionsAllDescribeThemselves() {
        // The description is what the inference prompt reads; an empty one makes
        // that section invisible to the model.
        for section in StoreService.namedDepartments {
            XCTAssertFalse(section.name.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertFalse((section.description ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(section.id) has no description")
        }
    }
}
