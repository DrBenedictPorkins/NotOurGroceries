import Foundation

/// Turning "aisle sixteen" into an aisle.
///
/// Deliberately not a model call. The input is one to three words from a very
/// small vocabulary — a number, or a department name — and a regular expression
/// gets it right every time for free, offline, in a shop with no signal. The one
/// AI-shaped part of aisle capture is the speech recogniser, and that runs on the
/// device too.
enum AisleUtterance {

    /// What a spoken phrase resolved to.
    enum Resolution: Equatable {
        /// Matches an aisle the store already has. Reuse it — never make a second.
        case existing(StoreAisle)
        /// Nothing like it in this store yet; creating it is the point.
        case new(number: String, name: String)
        /// Nothing usable was said.
        case rejected(reason: String)
    }

    /// Longest thing anybody says when naming an aisle. Past this it is a
    /// sentence — "I think it was near the back somewhere" — and saving it would
    /// put a paragraph in a section header.
    private static let maxLabelLength = 40

    static func resolve(_ spoken: String, in layout: [StoreAisle]) -> Resolution {
        let label = normalise(spoken)

        guard !label.isEmpty else {
            return .rejected(reason: "Didn't catch that.")
        }
        guard label.count <= maxLabelLength else {
            return .rejected(reason: "That's a sentence, not an aisle.")
        }

        if let existing = findExisting(label, in: layout) {
            return .existing(existing)
        }

        // A bare integer is an aisle number; anything else is a department name.
        // `StoreAisle` carries both fields and renders whichever is filled, so
        // the distinction is made once, here.
        if isBareNumber(label) {
            return .new(number: label, name: "")
        }
        return .new(number: "", name: label)
    }

    // MARK: - Normalising

    /// The spoken phrase reduced to a bare aisle label.
    static func normalise(_ spoken: String) -> String {
        var text = spoken
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))

        // "International, middle" — the part after the comma is where in the aisle
        // it sits, which no plaque prints and any manager can change by moving a
        // bay. Keeping it would also make an aisle literally called
        // "International, Middle". Cut at the comma and keep the place.
        if let comma = text.firstIndex(of: ",") {
            text = String(text[text.startIndex..<comma])
        }

        text = text.replacingOccurrences(
            of: "^(it'?s +)?(in +)?(the +)?aisle *",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.trimmingCharacters(in: .whitespaces)

        if let digits = numberFromWords(text) {
            return digits
        }
        return isBareNumber(text) ? text : titleCased(text)
    }

    private static func isBareNumber(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 3 && text.allSatisfy(\.isNumber)
    }

    /// "sixteen" → "16".
    ///
    /// The recogniser returns digits for some utterances and words for others,
    /// with no way to insist. Both have to land on the same aisle or a store ends
    /// up with a 16 *and* a Sixteen holding half the items each.
    static func numberFromWords(_ text: String) -> String? {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 2 else { return nil }

        if words.count == 1 {
            return units[words[0]].map(String.init)
        }
        // "twenty four" — tens first, then a unit under ten.
        guard let tens = tens[words[0]], let unit = units[words[1]], unit < 10 else {
            return nil
        }
        return String(tens + unit)
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30,
    ]

    private static let tens: [String: Int] = ["twenty": 20, "thirty": 30]

    private static func titleCased(_ text: String) -> String {
        text.split(separator: " ").map { word -> String in
            // "&" and "-" are not words and must not be capitalised into "&".
            guard let first = word.first, first.isLetter else { return String(word) }
            return first.uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    // MARK: - Matching what is already there

    /// Exact first, through the one place that knows how ids, names and numbers
    /// relate. Then a looser pass, because somebody standing in front of the
    /// dairy cabinet says "dairy", not "Dairy & Eggs".
    static func findExisting(_ label: String, in layout: [StoreAisle]) -> StoreAisle? {
        if let exact = AisleNaming.match(label, in: layout) {
            return exact
        }

        let key = comparisonKey(label)
        guard key.count >= 4 else { return nil }

        return layout.first { aisle in
            for candidate in [aisle.name, aisle.number] where !candidate.isEmpty {
                let other = comparisonKey(candidate)
                guard !other.isEmpty else { continue }
                if other.hasPrefix(key) || key.hasPrefix(other) { return true }
            }
            return false
        }
    }

    /// Letters and digits only, lowercased — so "Dairy & Eggs" and "dairy" can be
    /// compared without punctuation or spacing getting in the way.
    private static func comparisonKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
