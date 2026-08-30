import XCTest
@testable import GroceryApp

/// The track record is the one screen in the app that asserts things about the
/// past, so its arithmetic has to be right or it quietly lies. These tests care
/// about the derivations — grouping, ordering, gaps, and the difference between
/// "zero" and "not recorded".
final class TripLogTests: XCTestCase {

    // MARK: - Helpers

    private func trip(store: String = "Wegmans",
                      items: [String] = ["Milk"],
                      leftBehind: Int? = 0,
                      leftBehindNames: [String]? = nil,
                      minutes: Double = 30,
                      endedAt: Date = Date()) -> TripRecord {
        TripRecord(
            storeName: store,
            itemsPickedUp: items.count,
            startedAt: endedAt.addingTimeInterval(-minutes * 60),
            endedAt: endedAt,
            itemNames: items,
            leftBehind: leftBehind,
            leftBehindNames: leftBehindNames,
            customLearned: 0
        )
    }

    // MARK: - Empty

    func testEmptyLogAssertsNothing() {
        let log = TripLog()

        XCTAssertFalse(log.hasAnything)
        XCTAssertEqual(log.tripCount, 0)
        XCTAssertEqual(log.itemsPickedUp, 0)
        XCTAssertNil(log.averageMinutes)
        XCTAssertNil(log.favouriteStore)
        XCTAssertNil(log.longestTrip)
        XCTAssertNil(log.totalLeftBehind)
        XCTAssertTrue(log.topItems().isEmpty)
        // Not a row of zeroes — no chart at all, so an empty phone cannot be
        // mistaken for eight weeks of not shopping.
        XCTAssertTrue(log.tripsByWeek().isEmpty)
    }

    func testQuickTripAloneCountsAsSomething() {
        var log = TripLog()
        log.recordQuickRun(itemNames: ["Milk"], picked: 1)

        XCTAssertTrue(log.hasAnything)
        XCTAssertEqual(log.tripCount, 0, "a quick trip is not a store trip")
        XCTAssertEqual(log.quickTrips, 1)
    }

    // MARK: - Totals

    func testItemsPickedUpSumsAcrossTrips() {
        var log = TripLog()
        log.trips = [
            trip(items: ["Milk", "Eggs"]),
            trip(items: ["Bread"])
        ]

        XCTAssertEqual(log.itemsPickedUp, 3)
    }

    func testAverageMinutesRoundsAndNeverReturnsZero() {
        var log = TripLog()
        log.trips = [trip(minutes: 40), trip(minutes: 20)]
        XCTAssertEqual(log.averageMinutes, 30)

        // A 20-second trip is still a trip; reporting "0 min" reads as broken.
        var brief = TripLog()
        brief.trips = [trip(minutes: 0.33)]
        XCTAssertEqual(brief.averageMinutes, 1)
    }

    // MARK: - "Not recorded" is not "zero"

    func testLeftBehindIsNilWhenNoTripRecordedIt() {
        var log = TripLog()
        // A trip written by the build before the field existed.
        log.trips = [trip(leftBehind: nil)]

        XCTAssertNil(log.totalLeftBehind,
                     "reporting 0 would claim nothing was ever left behind")
    }

    func testLeftBehindSumsOnlyTripsThatRecordedIt() {
        var log = TripLog()
        log.trips = [trip(leftBehind: nil), trip(leftBehind: 3), trip(leftBehind: 2)]

        XCTAssertEqual(log.totalLeftBehind, 5)
    }

    // MARK: - Records

    func testLongestShortestAndBiggestPickTheRightTrips() {
        var log = TripLog()
        log.trips = [
            trip(store: "Aldi", items: ["a"], minutes: 10),
            trip(store: "Wegmans", items: ["a", "b", "c"], minutes: 75),
            trip(store: "Costco", items: ["a", "b"], minutes: 45)
        ]

        XCTAssertEqual(log.longestTrip?.storeName, "Wegmans")
        XCTAssertEqual(log.shortestTrip?.storeName, "Aldi")
        XCTAssertEqual(log.biggestHaul?.storeName, "Wegmans")
    }

    // MARK: - Stores

    func testFavouriteStoreIsTheMostVisited() {
        var log = TripLog()
        log.trips = [trip(store: "Aldi"), trip(store: "Wegmans"), trip(store: "Wegmans")]

        XCTAssertEqual(log.favouriteStore, "Wegmans")
    }

    func testFavouriteStoreBreaksTiesDeterministically() {
        var log = TripLog()
        log.trips = [trip(store: "Wegmans"), trip(store: "Aldi")]

        // Dictionary ordering is unstable, so without a tiebreak this answer
        // would change between launches for no reason the user can see.
        XCTAssertEqual(log.favouriteStore, "Aldi")
        XCTAssertEqual(log.favouriteStore, TripLog(trips: log.trips.reversed()).favouriteStore)
    }

    func testStoreBreakdownIsOrderedByVisits() {
        var log = TripLog()
        log.trips = [
            trip(store: "Aldi"), trip(store: "Wegmans"),
            trip(store: "Wegmans"), trip(store: "Wegmans")
        ]

        let breakdown = log.storeBreakdown
        XCTAssertEqual(breakdown.map(\.store), ["Wegmans", "Aldi"])
        XCTAssertEqual(breakdown.map(\.trips), [3, 1])
    }

    // MARK: - Top items

    func testTopItemsGroupsCaseAndWhitespaceInsensitively() {
        var log = TripLog()
        log.trips = [trip(items: ["Whole Milk", "whole milk", "  WHOLE MILK  "])]

        let top = log.topItems()
        XCTAssertEqual(top.count, 1, "one product, three spellings")
        XCTAssertEqual(top[0].count, 3)
    }

    func testTopItemsLabelsWithTheCommonestSpelling() {
        var log = TripLog()
        log.trips = [trip(items: ["whole milk", "Whole Milk", "Whole Milk"])]

        XCTAssertEqual(log.topItems()[0].name, "Whole Milk")
    }

    func testTopItemsCountsQuickTripsToo() {
        var log = TripLog()
        log.trips = [trip(items: ["Milk"])]
        log.recordQuickRun(itemNames: ["Milk", "Bread"], picked: 1)

        let top = log.topItems()
        XCTAssertEqual(top.first?.name, "Milk")
        XCTAssertEqual(top.first?.count, 2)
        XCTAssertEqual(top.map(\.name).sorted(), ["Bread", "Milk"])
    }

    func testTopItemsIgnoresBlankNames() {
        var log = TripLog()
        log.trips = [trip(items: ["Milk", "   ", ""])]

        XCTAssertEqual(log.topItems().map(\.name), ["Milk"])
    }

    func testTopItemsRespectsTheLimitAndOrdersByCount() {
        var log = TripLog()
        log.trips = [trip(items: ["a", "a", "a", "b", "b", "c", "d", "e", "f"])]

        let top = log.topItems(limit: 3)
        XCTAssertEqual(top.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(top.map(\.count), [3, 2, 1])
    }

    func testTopItemsBreaksTiesAlphabetically() {
        var log = TripLog()
        log.trips = [trip(items: ["pears", "apples"])]

        // Equal counts; without a tiebreak the order comes from Dictionary and
        // reshuffles between launches.
        XCTAssertEqual(log.topItems().map(\.name), ["apples", "pears"])
    }

    // MARK: - Weekly chart

    private func mondayCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    func testTripsByWeekFillsEmptyWeeks() {
        let calendar = mondayCalendar()
        let now = Date(timeIntervalSince1970: 1_756_512_000)   // 2025-08-30, a Saturday
        let threeWeeksAgo = calendar.date(byAdding: .weekOfYear, value: -3, to: now)!

        var log = TripLog()
        log.trips = [trip(endedAt: now), trip(endedAt: threeWeeksAgo)]

        let weeks = log.tripsByWeek(weeks: 4, now: now, calendar: calendar)

        XCTAssertEqual(weeks.count, 4)
        // Oldest first: the trip three weeks back, two quiet weeks, then today.
        XCTAssertEqual(weeks.map(\.trips), [1, 0, 0, 1])
    }

    func testTripsByWeekIsOldestFirst() {
        let calendar = mondayCalendar()
        let now = Date(timeIntervalSince1970: 1_756_512_000)

        var log = TripLog()
        log.trips = [trip(endedAt: now)]

        let weeks = log.tripsByWeek(weeks: 4, now: now, calendar: calendar)
        let starts = weeks.map(\.weekStart)
        XCTAssertEqual(starts, starts.sorted(),
                       "a chart drawn right-to-left reads as a decline")
    }

    func testTripsByWeekExcludesTripsOlderThanTheWindow() {
        let calendar = mondayCalendar()
        let now = Date(timeIntervalSince1970: 1_756_512_000)
        let longAgo = calendar.date(byAdding: .weekOfYear, value: -20, to: now)!

        var log = TripLog()
        log.trips = [trip(endedAt: longAgo)]

        let weeks = log.tripsByWeek(weeks: 4, now: now, calendar: calendar)
        XCTAssertEqual(weeks.map(\.trips), [0, 0, 0, 0])
        XCTAssertEqual(log.tripCount, 1, "still counted in the totals, just off the chart")
    }

    // MARK: - Recording

    func testRecordDerivesCountsFromNames() {
        var log = TripLog()
        log.record(storeName: "Aldi",
                   itemNames: ["Milk", "Eggs"],
                   leftBehindNames: ["Bread"],
                   customLearned: 0,
                   startedAt: Date().addingTimeInterval(-600),
                   endedAt: Date())

        XCTAssertEqual(log.trips.first?.itemsPickedUp, 2)
        XCTAssertEqual(log.trips.first?.itemNames, ["Milk", "Eggs"])
        XCTAssertEqual(log.trips.first?.leftBehind, 1)
        XCTAssertEqual(log.trips.first?.leftBehindNames, ["Bread"])
    }

    // MARK: - Restoring a trip

    func testEverythingOnTheListJoinsBothHalves() {
        let t = trip(items: ["Milk", "Eggs"], leftBehindNames: ["Bread"])
        XCTAssertEqual(t.everythingOnTheList, ["Milk", "Eggs", "Bread"])
    }

    func testEverythingOnTheListDropsDuplicatesAcrossHalves() {
        // A name can legitimately appear in both halves; restoring it twice
        // would put two of the same row back on the list.
        let t = trip(items: ["Milk"], leftBehindNames: ["milk", "Bread"])
        XCTAssertEqual(t.everythingOnTheList, ["Milk", "Bread"])
    }

    func testEverythingOnTheListIgnoresBlankNames() {
        let t = trip(items: ["Milk", "  "], leftBehindNames: [""])
        XCTAssertEqual(t.everythingOnTheList, ["Milk"])
    }

    func testRestorableTripIgnoresTripsWithNoNames() {
        var log = TripLog()
        log.trips = [
            trip(store: "Aldi", items: ["Milk"], leftBehindNames: ["Bread"]),
            // Written by the first build: counts only, nothing to put back.
            TripRecord(storeName: "Wegmans", itemsPickedUp: 4,
                       startedAt: Date(), endedAt: Date())
        ]

        XCTAssertEqual(log.lastTrip?.storeName, "Wegmans", "it is still the last trip")
        XCTAssertEqual(log.restorableTrip?.storeName, "Aldi",
                       "but the newest trip that can actually be restored is Aldi")
    }

    func testRestorableTripIsNilWhenNothingCanBeRestored() {
        var log = TripLog()
        log.trips = [TripRecord(storeName: "Wegmans", itemsPickedUp: 4,
                                startedAt: Date(), endedAt: Date())]

        XCTAssertNil(log.restorableTrip)
    }

    func testRestorableTripPrefersTheMostRecent() {
        var log = TripLog()
        log.trips = [
            trip(store: "Aldi", items: ["Milk"]),
            trip(store: "Costco", items: ["Eggs"])
        ]

        XCTAssertEqual(log.restorableTrip?.storeName, "Costco")
    }

    func testRecordQuickRunKeepsCounterAndLogInStep() {
        var log = TripLog()
        log.recordQuickRun(itemNames: ["Milk"], picked: 1)
        log.recordQuickRun(itemNames: ["Bread"], picked: 0)

        XCTAssertEqual(log.quickTrips, 2)
        XCTAssertEqual(log.runs.count, 2)
    }

    // MARK: - Decoding older files

    func testDecodesAFileWrittenBeforeTheNewFieldsExisted() throws {
        // Exactly what the first build wrote: no itemNames, no leftBehind, no
        // customLearned, no quickRuns.
        let json = """
        {
          "trips": [
            {
              "id": "abc",
              "storeName": "Wegmans",
              "itemsPickedUp": 7,
              "startedAt": "2026-08-29T10:00:00Z",
              "endedAt": "2026-08-29T10:40:00Z"
            }
          ],
          "quickTrips": 2
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let log = try decoder.decode(TripLog.self, from: json)

        XCTAssertEqual(log.tripCount, 1)
        XCTAssertEqual(log.itemsPickedUp, 7)
        XCTAssertEqual(log.quickTrips, 2)
        XCTAssertEqual(log.averageMinutes, 40)
        XCTAssertNil(log.totalLeftBehind)
        XCTAssertTrue(log.topItems().isEmpty, "no names were kept, so none can be shown")
    }

    // MARK: - Signing out

    @MainActor
    func testClearingLeavesNothingBehindForTheNextAccount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TripStatsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TripStats.directoryOverride = dir
        defer {
            TripStats.directoryOverride = nil
            try? FileManager.default.removeItem(at: dir)
        }

        let stats = TripStats()
        stats.recordTrip(storeName: "Wegmans",
                         itemNames: ["Milk"],
                         leftBehindNames: [],
                         customLearned: 0,
                         startedAt: Date().addingTimeInterval(-600),
                         endedAt: Date())
        XCTAssertTrue(stats.hasAnything)

        stats.clear()

        XCTAssertFalse(stats.hasAnything)
        XCTAssertEqual(stats.tripCount, 0)
        XCTAssertNil(stats.restorableTrip,
                     "a restore offer would rebuild the previous account's list")

        // Cleared in memory is not enough — the next launch reads the file.
        let reloaded = TripStats()
        XCTAssertFalse(reloaded.hasAnything)
    }

    func testRoundTripsThroughJSON() throws {
        var log = TripLog()
        log.record(storeName: "Aldi",
                   itemNames: ["Milk"],
                   leftBehindNames: ["Bread", "Jam"],
                   customLearned: 1,
                   startedAt: Date(timeIntervalSince1970: 1_000_000),
                   endedAt: Date(timeIntervalSince1970: 1_002_400))
        log.recordQuickRun(itemNames: ["Bread"], picked: 1,
                           at: Date(timeIntervalSince1970: 1_003_000))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(TripLog.self, from: encoder.encode(log))
        XCTAssertEqual(restored, log)
    }
}
