import Foundation

/// The app's name, and the jokes that hang off it.
///
/// Kept in one place so the name can be played with freely without hunting
/// through views — and so a future rename is a single edit rather than a grep.
///
/// That claim was aspirational until 2026-09-05, when five other files still
/// spelled the name out: the QR handoff's rejection message, both of
/// `AisleSpeechService`'s permission strings, and both `ShareText` headers. They
/// all read `name` now, so changing the line below really does rename the app
/// everywhere in Swift.
///
/// Three things it does *not* reach, and a rename has to touch them by hand:
/// the two `INFOPLIST_KEY_CFBundleDisplayName` entries in the project file, the
/// App Store listing, and `taglines` below — the jokes are puns on this exact
/// name and none of them survive it. See the trademark note in the project's
/// session memory for why a fast rename is worth keeping cheap.
enum AppIdentity {

    /// The name. Matches CFBundleDisplayName and the App Store listing.
    ///
    /// The question mark is part of the name, the way it is in "Got Milk?" —
    /// without it the joke doesn't land, it just reads as a statement about
    /// herbs. Bundle identifiers, file paths and table names never see it.
    static let name = "Got Dill?"

    /// Where the privacy policy is published.
    ///
    /// App Store review requires a reachable policy URL for any app that creates
    /// accounts, and it has to load over HTTPS without signing in. The page
    /// itself is `site/privacy.html` in this repo; this constant is the only
    /// place the address appears, so moving it is a one-line change.
    static let privacyPolicyURL = URL(string: "https://got-dill.com/privacy")!

    /// The name for use *inside* a sentence, where a trailing "?" would read as
    /// the end of the sentence ("open the Got Dill? app"). Same rule newspapers
    /// use for Yahoo! — carry the punctuation when the name stands alone or
    /// closes the sentence, drop it mid-clause.
    static let nameInSentence = "Got Dill"

    /// Rotating subtitles for the splash and sign-in screens. The name is a
    /// straight line; these are the punchlines — and they're questions too, so
    /// the whole screen reads in one voice. Add freely — nothing depends on the
    /// count or the order.
    static let taglines = [
        "Honey, get dill?",
        "Got Dill, Hon?",
        "Fresh dill, maybe?",
        "We out of dill?",
        "Dill with it?",
        "A whole dill bunch?",
        "Big dill energy?",
        "Some kind of dill?",
        "No dill, no deal?",
        "Wilted dill, sad night?"
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
