import Foundation

/// The app's name, and the jokes that hang off it.
///
/// Kept in one place so the name can be played with freely without hunting
/// through views — and so a future rename is a single edit rather than a grep.
enum AppIdentity {

    /// The name. Matches CFBundleDisplayName and the App Store listing.
    static let name = "Got Dill"

    /// Rotating subtitles for the splash and sign-in screens. The name is a
    /// straight line; these are the punchlines. Add freely — nothing depends on
    /// the count or the order.
    static let taglines = [
        "Honey, get dill",
        "Got Dill, Hon?",
        "Fresh dill, please",
        "We're out of dill",
        "Dill with it",
        "A whole dill bunch",
        "Big dill energy",
        "Some kind of dill",
        "No dill, no deal",
        "Wilted dill, sad night"
    ]

    /// A different one each launch. Deliberately random rather than sequential —
    /// the joke is better when it isn't predictable.
    static func randomTagline() -> String {
        taglines.randomElement() ?? taglines[0]
    }

    /// Used in invites and emails, where the name needs a little context for
    /// someone who has never heard of it.
    static let shortDescription = "Shared shopping lists for households"
}
