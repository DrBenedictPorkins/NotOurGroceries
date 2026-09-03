import Foundation

/// Turning an aisle id into something a person would say out loud.
///
/// Aisle ids are storage keys — `standard-frozen`, `7`, or whatever a store's
/// own layout calls them. They leaked onto screen anywhere a view printed the id
/// straight out of a mapping, so the batch mapper offered "standard-household"
/// as if that were the name of a place in the shop.
///
/// Resolution order, most authoritative first:
/// 1. the store's own layout, which is the only source that knows a section is
///    called "Aisle 7 — Baking" in this particular shop;
/// 2. a bare number, which is an aisle number;
/// 3. one of the built-in `standard-` ids, tidied up;
/// 4. the id itself, because a name we cannot improve on is better than a
///    placeholder that hides it.
enum AisleNaming {

    /// Human-readable name for an aisle id, in title case.
    static func displayName(for aisleId: String, in layout: [StoreAisle]) -> String {
        let id = aisleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return "Unsorted" }

        if let aisle = match(id, in: layout) {
            return label(for: aisle)
        }

        if let number = Int(id) {
            return "Aisle \(number)"
        }

        if let tidied = tidiedStandardId(id) {
            return tidied
        }

        // Last resort used to be the id itself. For a `standard-` slug that was
        // an improvement on nothing; for a UUID it is never right — it belongs to
        // an aisle that is no longer in this store's layout, and printing it puts
        // 36 characters of hex where a place name goes.
        return looksLikeUUID(id) ? "Unsorted" : id
    }

    private static func looksLikeUUID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// The same name, upper-cased for a section header.
    static func headerName(for aisleId: String, in layout: [StoreAisle]) -> String {
        displayName(for: aisleId, in: layout).uppercased()
    }

    /// An id can be stored as the aisle's id, its name, or its number depending
    /// on which build wrote the mapping, so all three are worth matching.
    static func match(_ aisleId: String, in layout: [StoreAisle]) -> StoreAisle? {
        let key = aisleId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return layout.first {
            $0.id.lowercased() == key
                || $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key
                || $0.number.trimmingCharacters(in: .whitespaces).lowercased() == key
        }
    }

    /// A header, not a description of the shelf.
    ///
    /// "Aisle 7 — Baking" when a store numbers its aisles and the name is short,
    /// just the name when there is no number, and the number alone when the name
    /// is really the aisle's contents.
    ///
    /// That last case is the common one. A directory scan fills `name` with a
    /// sample of what the sign listed — "sanitary products, sports braces, sports
    /// nutrition…" — which produced section headers three lines deep in At Store
    /// mode. The contents live in `description`, which is what the aisle
    /// inference prompt reads; a header only has to say which aisle it is.
    private static let maxNameInHeader = 20

    private static func label(for aisle: StoreAisle) -> String {
        let number = aisle.number.trimmingCharacters(in: .whitespaces)
        let name = aisle.name.trimmingCharacters(in: .whitespaces)
        let numbered = Int(number) != nil

        switch (number.isEmpty, name.isEmpty) {
        case (true, true):
            return "Unsorted"
        case (true, false):
            // No number to fall back on, so the name has to serve — but a
            // contents blob still gets cut at its first item rather than run on.
            return shortened(name)
        case (false, true):
            return numbered ? "Aisle \(number)" : number
        case (false, false):
            let prefix = numbered ? "Aisle \(number)" : number
            // A short name is a real name — "Baking". A long one is contents.
            guard name.count <= maxNameInHeader else { return prefix }
            return "\(prefix) — \(name)"
        }
    }

    /// First listed thing, and no more than a header's worth of it.
    private static func shortened(_ name: String) -> String {
        let firstPart = name.split(separator: ",").first.map(String.init) ?? name
        let trimmed = firstPart.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard trimmed.count > maxNameInHeader else { return trimmed }
        return String(trimmed.prefix(maxNameInHeader)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `standard-frozen` → `Frozen`, by looking it up rather than guessing, so
    /// the name matches what the section is actually called elsewhere.
    private static func tidiedStandardId(_ id: String) -> String? {
        guard id.lowercased().hasPrefix("standard-") else { return nil }

        if let known = StoreService.namedDepartments.first(where: {
            $0.id.lowercased() == id.lowercased()
        }) {
            return known.name
        }

        // An id in the standard shape that is not one of ours — a model made it
        // up, or it predates a rename. Better as words than as a slug.
        return id.dropFirst("standard-".count)
            .split(separator: "-")
            .map(\.capitalized)
            .joined(separator: " ")
    }
}
