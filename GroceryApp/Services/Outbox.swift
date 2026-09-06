import Foundation

/// Changes made while the server was unreachable, waiting to be pushed.
///
/// Without this, offline is a lie: `loadShoppingList` replaces `items` wholesale
/// on the next successful fetch, so everything crossed off in a dead zone
/// silently reverts the moment signal returns.
///
/// It records *which items changed*, not a log of mutations. The local
/// `GroceryItem` already holds the truth, so replay pushes its current state.
/// That collapses repeated edits — three taps on the same row while offline is
/// one write — and removes any question of replaying in the right order, which a
/// mutation log would have to get right and would get wrong the first time two
/// edits raced.
///
/// Deliberately a file, like `LocalListStore`. The queue is small, is rewritten
/// wholesale, and must be readable before Amplify has configured.
@MainActor
final class Outbox: ObservableObject {
    static let shared = Outbox()

    /// What has to happen to this item when we get back online.
    enum Kind: String, Codable {
        /// Created offline — the server has never seen it.
        case create
        /// Exists on the server; local status/notes/quantity are newer.
        case update
        /// Deleted offline.
        case delete
    }

    struct Entry: Codable, Identifiable, Equatable {
        let id: String          // itemId — one entry per item, by construction
        var kind: Kind
        var queuedAt: Date
        /// How many times pushing this has failed.
        ///
        /// Without it an entry the server will *never* accept — a create whose
        /// row already exists, an update for a row somebody deleted — stays
        /// queued for ever. That used to freeze the whole list, because
        /// `loadShoppingList` discards every fetch while the queue is non-empty.
        /// One poisoned entry silently cost a household every update from every
        /// other member, permanently, with pull-to-refresh doing nothing.
        var attempts: Int = 0
    }

    /// Give up after this many. Generous, because the common case is a real
    /// outage and those recover; anything still failing after five separate
    /// flushes is not coming back.
    static let maxAttempts = 5

    @Published private(set) var entries: [Entry] = [] {
        didSet { save() }
    }

    /// Tests point this at a temp directory; the test target is hosted inside the
    /// app and would otherwise stamp on the real queue.
    static var directoryOverride: URL?

    private static let filename = "outbox.json"

    private static var fileURL: URL? {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(filename)
        }
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    private init() { load() }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func contains(_ itemId: String) -> Bool {
        entries.contains { $0.id == itemId }
    }

    /// One entry per item. The transitions that matter:
    ///
    /// - create then update  → still a create; the server has never seen it
    /// - create then delete  → nothing at all; it never existed anywhere else
    /// - update then delete  → a delete
    ///
    /// Getting these wrong means pushing an update for a row the server does not
    /// have, or resurrecting something the user deleted.
    func enqueue(_ itemId: String, _ kind: Kind) {
        if let index = entries.firstIndex(where: { $0.id == itemId }) {
            let existing = entries[index].kind

            if existing == .create && kind == .delete {
                entries.remove(at: index)
                return
            }
            if existing == .create && kind == .update {
                return   // still a create
            }
            entries[index].kind = kind
            entries[index].queuedAt = Date()
            return
        }
        entries.append(Entry(id: itemId, kind: kind, queuedAt: Date()))
    }

    func remove(_ itemId: String) {
        entries.removeAll { $0.id == itemId }
    }

    /// Record a failed push. Returns true if the entry was given up on, so the
    /// caller can say so out loud rather than dropping a change in silence.
    @discardableResult
    func recordFailure(_ itemId: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == itemId }) else { return false }
        entries[index].attempts += 1
        if entries[index].attempts >= Self.maxAttempts {
            print("[OUTBOX] giving up on \(entries[index].kind.rawValue) for \(itemId) after \(entries[index].attempts) attempts")
            entries.remove(at: index)
            return true
        }
        return false
    }

    /// Item ids with work pending, for the merge in `loadShoppingList`.
    var pendingIds: Set<String> { Set(entries.map(\.id)) }

    /// Entries the server has already refused more than once.
    ///
    /// One failure is a bad moment on a train. Two or more, with the server
    /// reachable, means this change is not going to be accepted and the person
    /// should be told rather than left watching a list that never updates.
    var stuckEntries: [Entry] { entries.filter { $0.attempts >= 2 } }
    var hasStuckWork: Bool { !stuckEntries.isEmpty }

    func clear() {
        entries = []
    }

    // MARK: - Persistence

    private var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    private func save() {
        guard let url = Self.fileURL else { return }
        do {
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            print("[OUTBOX] save failed — \(error)")
        }
    }

    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url) else { return }
        do {
            entries = try decoder.decode([Entry].self, from: data)
            if !entries.isEmpty {
                print("[OUTBOX] restored \(entries.count) pending change(s)")
            }
        } catch {
            print("[OUTBOX] load failed — \(error)")
            entries = []
        }
    }
}
