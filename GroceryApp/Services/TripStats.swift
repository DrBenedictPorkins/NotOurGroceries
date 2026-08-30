import Foundation

// MARK: - Records

/// One finished At Store trip.
///
/// New fields are optional so a file written by an older build still decodes.
/// Synthesised `Codable` does not fall back to a property's default value when a
/// key is missing — it throws — so an optional is the only thing that survives
/// the upgrade.
struct TripRecord: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    let storeName: String
    let itemsPickedUp: Int
    let startedAt: Date
    let endedAt: Date

    /// What ended up in the cart. Names only — no ids, nothing pointing back at
    /// a household row.
    var itemNames: [String]?
    /// Still on the list when you called it done.
    var leftBehind: Int?
    /// …and what they were, so the whole trip can be put back.
    var leftBehindNames: [String]?
    /// Items typed by hand that the app had never seen before.
    var customLearned: Int?

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    var minutes: Int { max(1, Int(duration / 60)) }

    /// The list as it stood when the trip started: what you picked up plus what
    /// you did not. Duplicates removed case-insensitively, since a name that
    /// appears in both halves is one item, not two.
    var everythingOnTheList: [String] {
        var seen = Set<String>()
        return ((itemNames ?? []) + (leftBehindNames ?? [])).filter {
            let key = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
    }
}

/// One finished Quick Trip. Lighter than a trip: no store, no clock — the list
/// is a scratch pad you wipe on the way out.
struct QuickRunRecord: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    let finishedAt: Date
    let itemNames: [String]
    /// How many were ticked off before you cleared it.
    let picked: Int
}

// MARK: - The log

/// Everything counted, and every question you can ask of it.
///
/// A plain value type on purpose: all the derivation lives here, so it can be
/// exercised directly without a singleton, a file, or a main actor.
struct TripLog: Codable, Equatable {
    var trips: [TripRecord] = []
    /// Kept as a plain counter for files written before `quickRuns` existed.
    var quickTrips: Int = 0
    var quickRuns: [QuickRunRecord]?

    var runs: [QuickRunRecord] { quickRuns ?? [] }

    var hasAnything: Bool { !trips.isEmpty || quickTrips > 0 }
    var tripCount: Int { trips.count }
    var itemsPickedUp: Int { trips.reduce(0) { $0 + $1.itemsPickedUp } }
    var lastTrip: TripRecord? { trips.last }

    /// Left on the list across every trip. Nil until at least one trip recorded
    /// the field — trips written by the first build did not, and counting those
    /// as zero would quietly understate it.
    var totalLeftBehind: Int? {
        let known = trips.compactMap(\.leftBehind)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// The store you finish at most often. Nil until there is a trip to count.
    var favouriteStore: String? {
        let counts = Dictionary(grouping: trips, by: \.storeName).mapValues(\.count)
        // Ties broken by name so the answer does not change between launches.
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Average minutes in the store, rounded. Nil until there is a trip.
    var averageMinutes: Int? {
        guard !trips.isEmpty else { return nil }
        let total = trips.reduce(0.0) { $0 + $1.duration }
        return max(1, Int((total / Double(trips.count)) / 60))
    }

    var longestTrip: TripRecord? { trips.max { $0.duration < $1.duration } }
    var shortestTrip: TripRecord? { trips.min { $0.duration < $1.duration } }
    var biggestHaul: TripRecord? { trips.max { $0.itemsPickedUp < $1.itemsPickedUp } }

    /// How many trips each store has seen, most-visited first.
    var storeBreakdown: [(store: String, trips: Int)] {
        Dictionary(grouping: trips, by: \.storeName)
            .map { (store: $0.key, trips: $0.value.count) }
            .sorted { ($0.trips, $1.store) > ($1.trips, $0.store) }
    }

    /// What you buy most, across both kinds of trip.
    ///
    /// Grouped case- and whitespace-insensitively, then labelled with whichever
    /// spelling appeared most — so "whole milk" and "Whole Milk" are one row,
    /// written the way you usually write it.
    func topItems(limit: Int = 5) -> [(name: String, count: Int)] {
        var buckets: [String: [String]] = [:]
        let everything = trips.flatMap { $0.itemNames ?? [] } + runs.flatMap(\.itemNames)

        for raw in everything {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            buckets[name.lowercased(), default: []].append(name)
        }

        return buckets
            .map { (name: Self.mostCommon($0.value), count: $0.value.count) }
            // Ties broken alphabetically, so equal counts do not reshuffle
            // between launches on Dictionary's unstable ordering.
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(limit)
            .map { $0 }
    }

    private static func mostCommon(_ spellings: [String]) -> String {
        Dictionary(grouping: spellings, by: { $0 })
            .max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?
            .key ?? spellings[0]
    }

    /// Trips per calendar week, oldest first, with empty weeks filled in so a
    /// fortnight of not shopping reads as a gap rather than closing up.
    func tripsByWeek(weeks: Int = 8, now: Date = Date(),
                     calendar: Calendar = .current) -> [(weekStart: Date, trips: Int)] {
        guard !trips.isEmpty else { return [] }
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        else { return [] }

        let starts: [Date] = (0..<weeks).reversed().compactMap {
            calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }

        return starts.map { start in
            let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? start
            let count = trips.filter { $0.endedAt >= start && $0.endedAt < end }.count
            return (weekStart: start, trips: count)
        }
    }

    // MARK: Mutation

    mutating func record(storeName: String,
                         itemNames: [String],
                         leftBehindNames: [String],
                         customLearned: Int,
                         startedAt: Date,
                         endedAt: Date) {
        trips.append(
            TripRecord(storeName: storeName,
                       itemsPickedUp: itemNames.count,
                       startedAt: startedAt,
                       endedAt: endedAt,
                       itemNames: itemNames,
                       leftBehind: leftBehindNames.count,
                       leftBehindNames: leftBehindNames,
                       customLearned: customLearned)
        )
    }

    /// The most recent trip that kept enough to rebuild the list from.
    ///
    /// Trips written by the first build recorded only counts, so they can be
    /// counted but not restored — offering to restore one would put nothing
    /// back and look broken.
    var restorableTrip: TripRecord? {
        trips.last { !$0.everythingOnTheList.isEmpty }
    }

    mutating func recordQuickRun(itemNames: [String], picked: Int, at date: Date = Date()) {
        quickTrips += 1
        var existing = quickRuns ?? []
        existing.append(QuickRunRecord(finishedAt: date, itemNames: itemNames, picked: picked))
        quickRuns = existing
    }
}

// MARK: - The store

/// A tally of finished trips, kept on this phone.
///
/// Local on purpose. Every number is recorded as it happens — a trip counts when
/// you actually finish one, never derived or estimated — so a phone that has
/// never finished a trip starts at zero and says so rather than showing a
/// plausible-looking number.
///
/// Nothing historical is backfilled. The server has `Commit` rows that could
/// reconstruct earlier trips, and that is the obvious upgrade later; until then
/// this only knows what it has watched happen.
@MainActor
final class TripStats: ObservableObject {
    static let shared = TripStats()

    @Published private(set) var log = TripLog() {
        didSet { save() }
    }

    /// Tests point this at a temp directory; the test target is hosted inside
    /// the app and would otherwise stamp on the real tally.
    static var directoryOverride: URL?

    private static let filename = "trip-stats.json"

    private static var fileURL: URL? {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(filename)
        }
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    init() { load() }

    // MARK: Recording

    func recordTrip(storeName: String,
                    itemNames: [String],
                    leftBehindNames: [String],
                    customLearned: Int,
                    startedAt: Date,
                    endedAt: Date) {
        log.record(storeName: storeName,
                   itemNames: itemNames,
                   leftBehindNames: leftBehindNames,
                   customLearned: customLearned,
                   startedAt: startedAt,
                   endedAt: endedAt)
    }

    func recordQuickTrip(itemNames: [String], picked: Int) {
        log.recordQuickRun(itemNames: itemNames, picked: picked)
    }

    // MARK: Reading — passthrough, so views never reach past the log

    var hasAnything: Bool { log.hasAnything }
    var trips: [TripRecord] { log.trips }
    var quickRuns: [QuickRunRecord] { log.runs }
    var tripCount: Int { log.tripCount }
    var quickTripCount: Int { log.quickTrips }
    var itemsPickedUp: Int { log.itemsPickedUp }
    var lastTrip: TripRecord? { log.lastTrip }
    var restorableTrip: TripRecord? { log.restorableTrip }
    var totalLeftBehind: Int? { log.totalLeftBehind }
    var favouriteStore: String? { log.favouriteStore }
    var averageMinutes: Int? { log.averageMinutes }
    var longestTrip: TripRecord? { log.longestTrip }
    var shortestTrip: TripRecord? { log.shortestTrip }
    var biggestHaul: TripRecord? { log.biggestHaul }
    var storeBreakdown: [(store: String, trips: Int)] { log.storeBreakdown }
    func topItems(limit: Int = 5) -> [(name: String, count: Int)] { log.topItems(limit: limit) }
    func tripsByWeek(weeks: Int = 8) -> [(weekStart: Date, trips: Int)] {
        log.tripsByWeek(weeks: weeks)
    }

    // MARK: Persistence

    private var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private func save() {
        guard let url = Self.fileURL else { return }
        do {
            try encoder.encode(log).write(to: url, options: .atomic)
        } catch {
            print("[TRIPSTATS] save failed — \(error)")
        }
    }

    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return }
        do {
            log = try decoder.decode(TripLog.self, from: data)
        } catch {
            print("[TRIPSTATS] load failed — \(error)")
            log = TripLog()
        }
    }
}
