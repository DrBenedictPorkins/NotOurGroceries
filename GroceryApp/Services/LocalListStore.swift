import Foundation

/// The list on disk, so the app is never empty-handed.
///
/// The bar this has to clear: if the app crashes at the store and there is no
/// signal, reopening it must still show the list. That means reading this file
/// cannot depend on Amplify configuring, auth resolving, or a network call — it
/// is a plain JSON file and a plain decoder, nothing else.
///
/// Deliberately not a database. There is one list, it is small, and it is
/// rewritten wholesale. A file is the right size of tool.
enum LocalListStore {

    struct Snapshot: Codable {
        var items: [GroceryItem]
        var householdId: String?
        var savedAt: Date

        /// The rest of what a shopping trip needs. The list alone is not enough:
        /// arriving at the store with no signal and a cold app used to mean no
        /// store to pick and no aisle order, because both lived only in memory.
        /// These are already-computed values, so persisting them costs nothing
        /// and buys a fully working trip offline. Only inference for brand-new
        /// custom items still needs the network.
        ///
        /// Optional with defaults so a snapshot written by an older build still
        /// decodes — losing the list to a schema change would defeat the point.
        var stores: [HouseholdStore]?
        var aisleMappings: [String: [ProductAisleMapping]]?
    }

    static let filename = "shopping-list-snapshot.json"

    /// Tests point this at a temp directory. The test target is hosted inside the
    /// app, so without it a test run deletes the real snapshot out from under
    /// whoever is using the app on that simulator — and races the host app's own
    /// debounced write, which makes "nothing saved" assertions flaky.
    static var directoryOverride: URL?

    static var fileURL: URL? {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(filename)
        }
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Write

    static func save(
        items: [GroceryItem],
        householdId: String?,
        stores: [HouseholdStore]? = nil,
        aisleMappings: [String: [ProductAisleMapping]]? = nil
    ) {
        guard let url = fileURL else { return }
        // Never blank out context we already hold just because this caller did
        // not pass it — an item-only save must not cost the aisle mappings.
        let existing = load()
        let snapshot = Snapshot(
            items: items,
            householdId: householdId,
            savedAt: Date(),
            stores: stores ?? existing?.stores,
            aisleMappings: aisleMappings ?? existing?.aisleMappings
        )
        do {
            let data = try encoder.encode(snapshot)
            // .atomic so a crash mid-write can't leave a truncated file behind —
            // a corrupt snapshot would defeat the entire point of having one.
            try data.write(to: url, options: .atomic)
        } catch {
            print("LocalListStore: save failed — \(error)")
        }
    }

    // MARK: - Read

    /// Returns nil if there is no snapshot yet, or if it can't be read for any
    /// reason. Never throws: a failure here must degrade to "no local copy",
    /// never to a crash on launch.
    static func load() -> Snapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(Snapshot.self, from: data)
        } catch {
            print("LocalListStore: load failed — \(error)")
            return nil
        }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// How stale the local copy is, for telling the user what they're looking at.
    static func savedAtDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
