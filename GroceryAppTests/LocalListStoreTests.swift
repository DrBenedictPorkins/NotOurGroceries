import XCTest
@testable import GroceryApp

/// The local snapshot is what stands between a dead network at the store and an
/// empty screen. If it cannot round-trip an item faithfully, Paper List mode is
/// worthless — so these tests care about fidelity, not just "it saved something".
final class LocalListStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The test target is hosted inside the app, so without redirecting the
        // store these tests would delete the real snapshot and race the host
        // app's own debounced write.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalListStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        LocalListStore.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        LocalListStore.directoryOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func sampleItem() -> GroceryItem {
        GroceryItem(
            id: "item-1",
            householdId: "hh-1",
            name: "Bell Peppers",
            normalizedName: "bell pepper",
            quantity: "3",
            notes: "Red",
            notesEphemeral: true,
            isCustom: true,
            productId: "prod-9",
            status: .inCart,
            lockedBy: "someone",
            addedBy: "me",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            version: 7,
            images: [ItemImage(id: "img-1", s3Key: "item-images/x.jpg",
                               uploadedBy: "me",
                               uploadedAt: Date(timeIntervalSince1970: 1_700_000_000))]
        )
    }

    func testLoadReturnsNilWhenNothingSaved() {
        XCTAssertNil(LocalListStore.load(),
                     "No snapshot must read as 'no local copy', never as a crash")
    }

    func testRoundTripPreservesEveryField() throws {
        let original = sampleItem()
        LocalListStore.save(items: [original], householdId: "hh-1")

        let snapshot = try XCTUnwrap(LocalListStore.load())
        let restored = try XCTUnwrap(snapshot.items.first)

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.name, original.name)
        XCTAssertEqual(restored.normalizedName, original.normalizedName)
        XCTAssertEqual(restored.quantity, original.quantity)
        XCTAssertEqual(restored.notes, original.notes)
        XCTAssertEqual(restored.status, original.status)
        XCTAssertEqual(restored.version, original.version)
        // CodingKeys is hand-written, so a field added to the struct but missed
        // there round-trips as nil silently. productId in particular carries the
        // aisle mapping — losing it offline loses the item's shelf location.
        XCTAssertEqual(restored.productId, original.productId)
        XCTAssertEqual(restored.householdId, original.householdId)
        XCTAssertEqual(restored.lockedBy, original.lockedBy)
        XCTAssertEqual(restored.images.count, original.images.count)
        XCTAssertEqual(restored.addedAt.timeIntervalSince1970,
                       original.addedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(snapshot.householdId, "hh-1")
    }

    func testRoundTripPreservesTheFlagsThatDecideItemFate() throws {
        // notesEphemeral decides whether a note is wiped when the trip ends, and
        // isCustom whether the item is catalogued. Losing either across a restart
        // changes what the user sees on the shelf.
        LocalListStore.save(items: [sampleItem()], householdId: "hh-1")
        let restored = try XCTUnwrap(LocalListStore.load()?.items.first)

        XCTAssertTrue(restored.notesEphemeral)
        XCTAssertTrue(restored.isCustom)
    }

    func testSaveOverwritesRatherThanAppends() throws {
        LocalListStore.save(items: [sampleItem()], householdId: "hh-1")
        LocalListStore.save(items: [], householdId: "hh-1")

        let snapshot = try XCTUnwrap(LocalListStore.load())
        XCTAssertTrue(snapshot.items.isEmpty,
                      "An emptied list must persist as empty, not resurrect the previous one")
    }

    func testClearRemovesTheSnapshot() {
        LocalListStore.save(items: [sampleItem()], householdId: "hh-1")
        LocalListStore.clear()
        XCTAssertNil(LocalListStore.load())
    }

    func testCorruptFileDegradesToNoSnapshotRatherThanThrowing() throws {
        LocalListStore.save(items: [sampleItem()], householdId: "hh-1")

        let url = try XCTUnwrap(LocalListStore.fileURL)
        try Data("{ not json at all".utf8).write(to: url)

        // Must not throw. A bad snapshot means "no local copy", and the app
        // still has to launch.
        XCTAssertNil(LocalListStore.load())
    }

    func testManyItemsRoundTrip() throws {
        let items = (0..<250).map {
            GroceryItem(id: "i\($0)", householdId: "hh", name: "Item \($0)", addedBy: "me")
        }
        LocalListStore.save(items: items, householdId: "hh")

        XCTAssertEqual(LocalListStore.load()?.items.count, 250)
    }
}
