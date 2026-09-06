import XCTest
@testable import GroceryApp

/// A finished trip that could not be sent is held here until there is signal.
///
/// It is a list rather than a single slot for a specific reason: a day with no
/// signal can hold two finished trips, and if the second overwrote the first
/// then the first trip's items would stay `ACTIVE` on the server for ever —
/// suggestions on the phone, still on the list to everyone else, and dragged
/// back by the next refresh. These tests are about that: nothing queued is lost,
/// the oldest goes first, and one landing does not take another with it.
@MainActor
final class PendingFinishStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The test target is hosted inside the app, so without redirecting the
        // store a test run would delete whatever finish is genuinely waiting to
        // be sent on the simulator.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingFinishStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        PendingFinishStore.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        PendingFinishStore.directoryOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func finish(_ tripId: String,
                        created: [PendingFinish.CreatedItem] = [],
                        queuedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> PendingFinish {
        PendingFinish(tripId: tripId,
                      householdId: "hh-1",
                      toSuggestion: ["item-1", "item-2"],
                      clearNotesFor: ["item-2"],
                      created: created,
                      endTrip: true,
                      queuedAt: queuedAt)
    }

    private var waitingTripIds: [String] {
        PendingFinishStore.load().map(\.tripId)
    }

    // MARK: - Nothing waiting

    func testNothingIsPendingBeforeAnythingIsQueued() {
        XCTAssertEqual(PendingFinishStore.load(), [])
        XCTAssertNil(PendingFinishStore.next)
        XCTAssertFalse(PendingFinishStore.isPending)
    }

    // MARK: - Queuing

    func testTheOldestFinishIsTheOneSentNext() {
        PendingFinishStore.append(finish("trip-morning"))
        PendingFinishStore.append(finish("trip-evening"))

        XCTAssertEqual(PendingFinishStore.next?.tripId, "trip-morning",
                       "Trips must land in the order they happened")
    }

    func testASecondFinishDoesNotOverwriteTheFirst() {
        PendingFinishStore.append(finish("trip-morning"))
        PendingFinishStore.append(finish("trip-evening"))

        XCTAssertEqual(waitingTripIds, ["trip-morning", "trip-evening"],
                       "Losing the earlier trip leaves its items ACTIVE on the server for ever")
    }

    func testIsPendingFollowsWhatIsActuallyWaiting() {
        XCTAssertFalse(PendingFinishStore.isPending)

        PendingFinishStore.append(finish("trip-a"))
        XCTAssertTrue(PendingFinishStore.isPending)

        PendingFinishStore.append(finish("trip-b"))
        PendingFinishStore.remove(tripId: "trip-a")
        XCTAssertTrue(PendingFinishStore.isPending, "One landing does not clear the other")

        PendingFinishStore.remove(tripId: "trip-b")
        XCTAssertFalse(PendingFinishStore.isPending)
    }

    // MARK: - One landing

    /// A finish can be appended while an earlier one is in flight, so "the one
    /// that just landed" and "the one at the front" are not the same thing.
    func testRemovingTakesTheNamedTripAndNotThePositionItWasIn() {
        PendingFinishStore.append(finish("trip-a"))
        PendingFinishStore.append(finish("trip-b"))
        PendingFinishStore.append(finish("trip-c"))

        PendingFinishStore.remove(tripId: "trip-b")

        XCTAssertEqual(waitingTripIds, ["trip-a", "trip-c"])
    }

    func testRemovingTheOldestLeavesTheLaterOneWaiting() {
        PendingFinishStore.append(finish("trip-a"))
        PendingFinishStore.append(finish("trip-b"))

        PendingFinishStore.remove(tripId: "trip-a")

        XCTAssertEqual(waitingTripIds, ["trip-b"])
        XCTAssertEqual(PendingFinishStore.next?.tripId, "trip-b")
    }

    /// The reply to a finish can be lost, so the same one gets sent again and
    /// removed again. The second removal must not take a different trip with it.
    func testRemovingATripThatIsNotWaitingChangesNothing() {
        PendingFinishStore.append(finish("trip-a"))

        PendingFinishStore.remove(tripId: "trip-b")

        XCTAssertEqual(waitingTripIds, ["trip-a"])
    }

    func testClearDropsEverythingWaiting() {
        PendingFinishStore.append(finish("trip-a"))
        PendingFinishStore.append(finish("trip-b"))

        PendingFinishStore.clear()

        XCTAssertFalse(PendingFinishStore.isPending)
        XCTAssertNil(PendingFinishStore.next)
    }

    // MARK: - Surviving the trip to disk

    /// The whole point is that this survives the app being killed on the way
    /// home. An item added offline during the trip has never been seen by the
    /// server, so if it does not come back off disk intact it is simply gone.
    func testAFinishSurvivesBeingWrittenAndReadBack() throws {
        let created = PendingFinish.CreatedItem(
            id: "new-1",
            householdId: "hh-1",
            name: "Bell Peppers",
            normalizedName: "bell pepper",
            quantity: "3",
            notes: "Red ones",
            notesEphemeral: false,
            isCustom: true,
            productId: "prod-9",
            status: "SUGGESTION",
            addedBy: "me",
            addedAt: AmplifyService.formatAWSDateTime(Date(timeIntervalSince1970: 1_700_000_000)),
            version: 1
        )
        let original = finish("trip-a", created: [created])

        PendingFinishStore.append(original)

        let restored = try XCTUnwrap(PendingFinishStore.next)
        XCTAssertEqual(restored, original)

        let restoredItem = try XCTUnwrap(restored.created.first)
        XCTAssertEqual(restoredItem.name, "Bell Peppers")
        XCTAssertEqual(restoredItem.status, "SUGGESTION")
        XCTAssertEqual(restoredItem.productId, "prod-9")
        XCTAssertNotNil(AmplifyService.parseAWSDateTime(restoredItem.addedAt),
                        "addedAt has to still be a date AppSync will accept")
    }

    func testTheQueuedTimeSurvivesTheRoundTrip() throws {
        let queuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        PendingFinishStore.append(finish("trip-a", queuedAt: queuedAt))

        let restored = try XCTUnwrap(PendingFinishStore.next)
        XCTAssertEqual(restored.queuedAt.timeIntervalSince1970,
                       queuedAt.timeIntervalSince1970, accuracy: 1)
    }

    /// An unannounced trip — started with no signal — has no household status to
    /// put back. Losing that flag would make the phone try to end a trip the
    /// server never knew had started.
    func testWhetherTheTripWasEverAnnouncedSurvives() throws {
        let unannounced = PendingFinish(tripId: "trip-a",
                                        householdId: "hh-1",
                                        toSuggestion: [],
                                        clearNotesFor: [],
                                        created: [],
                                        endTrip: false,
                                        queuedAt: Date(timeIntervalSince1970: 1_700_000_000))
        PendingFinishStore.append(unannounced)

        XCTAssertEqual(try XCTUnwrap(PendingFinishStore.next).endTrip, false)
    }

    func testACorruptFileReadsAsNothingWaitingRatherThanThrowing() throws {
        PendingFinishStore.append(finish("trip-a"))
        let url = try XCTUnwrap(PendingFinishStore.fileURL)
        try Data("{ not json at all".utf8).write(to: url)

        // Must not throw. The app still has to launch, and the abandoned-session
        // path is what catches the trip left behind.
        XCTAssertEqual(PendingFinishStore.load(), [])
        XCTAssertNil(PendingFinishStore.next)
        XCTAssertFalse(PendingFinishStore.isPending)
    }

    // MARK: - Writing a finished item

    /// A trip-scoped note dies with the trip. Sending it up would resurrect it on
    /// an item that is now just a suggestion for next time.
    func testATripScopedNoteIsNotSentUpWithTheItem() {
        let item = GroceryItem(id: "i1", householdId: "hh-1", name: "Milk",
                               notes: "the small carton", notesEphemeral: true,
                               addedBy: "me")

        let created = PendingFinish.CreatedItem(finishing: item)

        XCTAssertNil(created.notes)
        XCTAssertFalse(created.notesEphemeral)
    }

    func testAPermanentNoteIsKept() {
        let item = GroceryItem(id: "i1", householdId: "hh-1", name: "Milk",
                               notes: "whole, not skimmed", notesEphemeral: false,
                               addedBy: "me")

        XCTAssertEqual(PendingFinish.CreatedItem(finishing: item).notes, "whole, not skimmed")
    }

    /// Whatever the item was during the trip, what the server is being told is
    /// that it is now a suggestion.
    func testAnItemAddedDuringTheTripTravelsAsASuggestion() {
        let item = GroceryItem(id: "i1", householdId: "hh-1", name: "Milk",
                               status: .inCart, addedBy: "me")

        let created = PendingFinish.CreatedItem(finishing: item)

        XCTAssertEqual(created.status, "SUGGESTION")
        XCTAssertEqual(created.id, "i1")
        XCTAssertNotNil(AmplifyService.parseAWSDateTime(created.addedAt))
    }
}
