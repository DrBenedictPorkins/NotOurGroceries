import Foundation

/// Handing a shopping list to a phone in another household.
///
/// The case this exists for: a guest offers to do the shop. They are not in the
/// household and putting them in it would be wrong — they would see the history,
/// the suggestions and every future list. So the list is copied, not shared, and
/// it lands in their Quick Trip, which is local to their phone and never syncs.
///
/// The carrier is a QR square rather than a file, AirDrop or a server round
/// trip: the app already draws and reads QR for household invites, so the
/// gesture is one people have met, and it needs no network at all — which
/// matters in a shop.
///
/// Names only. No quantities, aisles, store, or statuses, because a Quick Trip
/// line holds a name and a tick and nothing else. Everything arrives unticked.
enum ListHandoff {

    /// A QR square at correction level L tops out near 2,900 bytes, which is far
    /// more than this. The real ceiling is whether a phone camera can still
    /// resolve the modules: 50 names is an 81×81 square that reads instantly
    /// across a table, where 150 would be 161×161 and start failing on a smudged
    /// screen. Nobody sends a guest for more than fifty things anyway.
    static let maxItems = 50

    /// First line of the payload. Present so scanning the wrong square — a
    /// household invite, a packet of cereal — is refused rather than turned into
    /// a shopping list of gibberish. Versioned so a later format can be told
    /// apart from this one.
    private static let magic = "GOTDILL/1"

    /// Trimmed, emptied, de-duplicated, then capped. De-duplication runs before
    /// the cap so the fifty that travel are fifty real items.
    static func prepare(_ rawNames: [String]) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for raw in rawNames {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// What goes in the square. Plain text on purpose: anyone who scans it with
    /// a generic QR reader sees a readable shopping list instead of a blob.
    static func encode(_ names: [String]) -> String {
        ([magic] + prepare(names).prefix(maxItems)).joined(separator: "\n")
    }

    /// `nil` for anything that is not one of our lists.
    static func decode(_ payload: String) -> [String]? {
        var lines = payload.components(separatedBy: .newlines)
        guard let header = lines.first,
              header.trimmingCharacters(in: .whitespaces) == magic else { return nil }
        lines.removeFirst()
        let names = prepare(lines)
        return names.isEmpty ? nil : Array(names.prefix(maxItems))
    }
}
