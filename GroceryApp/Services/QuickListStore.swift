import Foundation
import Combine

/// A scratch list for "honey, what do I need?"
///
/// Deliberately not a GroceryItem and deliberately not on the server. It never
/// syncs, never becomes a suggestion, and nobody else can see it. That is the
/// entire point: the previous Quick Trip was a second household-visible mode
/// that showed the main list alongside it, which made it impossible to tell the
/// two apart — so it got used six times, all of them by us, testing.
///
/// It does survive relaunch, because the moment you need it is standing in a
/// shop, which is also the moment iOS is most likely to have killed the app.
@MainActor
final class QuickListStore: ObservableObject {
    static let shared = QuickListStore()

    struct Line: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var checked: Bool

        init(id: UUID = UUID(), name: String, checked: Bool = false) {
            self.id = id
            self.name = name
            self.checked = checked
        }
    }

    @Published private(set) var lines: [Line] = [] {
        didSet { save() }
    }

    /// Tests point this at a temp directory. Without it a test run would delete
    /// whatever is on the simulator's real quick list.
    static var directoryOverride: URL?

    private static let filename = "quick-list.json"

    private static var fileURL: URL? {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent(filename)
        }
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    private init() {
        load()
    }

    // MARK: - Mutations

    var isEmpty: Bool { lines.isEmpty }
    var remainingCount: Int { lines.filter { !$0.checked }.count }

    /// Adds unless the same name is already there. Case-insensitive, because
    /// nobody dictating a list is thinking about capitalisation.
    func add(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !lines.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        lines.append(Line(name: name))
    }

    /// Bulk add, for a dictated or pasted run of items.
    func add(contentsOf names: [String]) {
        for name in names { add(name) }
    }

    func toggle(_ line: Line) {
        guard let index = lines.firstIndex(where: { $0.id == line.id }) else { return }
        lines[index].checked.toggle()
    }

    func remove(_ line: Line) {
        lines.removeAll { $0.id == line.id }
    }

    /// Done. The list is disposable by design — there is no history to preserve
    /// and nothing to write to the household.
    func clear() {
        lines = []
    }

    // MARK: - Persistence

    private func save() {
        guard let url = Self.fileURL else { return }
        do {
            try JSONEncoder().encode(lines).write(to: url, options: .atomic)
        } catch {
            // A failed write costs the list on next launch, which is bad but not
            // worth interrupting someone mid-shop over.
            print("QuickListStore: save failed — \(error)")
        }
    }

    private func load() {
        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url) else { return }
        do {
            lines = try JSONDecoder().decode([Line].self, from: data)
        } catch {
            print("QuickListStore: load failed — \(error)")
            lines = []
        }
    }
}
