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

    static func save(items: [GroceryItem], householdId: String?) {
        guard let url = fileURL else { return }
        let snapshot = Snapshot(items: items, householdId: householdId, savedAt: Date())
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
