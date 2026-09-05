import Foundation
import CryptoKit

/// A cooling-off period between password-reset emails.
///
/// "Send Reset Code" takes any address and mails it a code, and the button sat
/// there ready to be pressed again immediately. Pressed repeatedly it turns the
/// app into a way to bury somebody else's inbox, and there is no sign-in
/// required to do it.
///
/// The state is on disk rather than in the view, because a cooldown that a
/// person can clear by closing the sheet or relaunching the app is not a
/// cooldown. Keyed per address: waiting on one address must not block a person
/// who simply mistyped theirs the first time.
///
/// Worth being clear about what this is. It stops the impatient double-tap and
/// the casual masher, which is most of the real traffic. It does not stop
/// somebody determined, who can delete the app or talk to Cognito directly —
/// only the server can stop that, and Cognito applies its own limits to these
/// calls. This is the honest path made well-behaved, not a security control.
enum ResendThrottle {

    /// Long enough that a second mail is a decision, short enough that somebody
    /// whose code genuinely did not arrive is not left stranded.
    static let cooldown: TimeInterval = 60

    private static let key = "resendThrottle.lastSent"

    /// Addresses are hashed before they are written. The cooldown only needs to
    /// recognise the same address again, and storing a plain list of every
    /// address typed into this screen — most of which will not be the user's own
    /// — is more than that needs.
    private static func fingerprint(_ email: String) -> String {
        let normalised = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normalised.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static var log: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Whole seconds left before this address may be mailed again; 0 when it may
    /// be sent now. Rounded up so a display never shows "0" while still blocked.
    static func secondsRemaining(for email: String, now: Date = Date()) -> Int {
        guard let sent = log[fingerprint(email)] else { return 0 }
        let elapsed = now.timeIntervalSince1970 - sent
        // A clock moved backwards would otherwise lock the address out for as
        // long as the clock was wrong.
        guard elapsed >= 0 else { return 0 }
        return max(0, Int((cooldown - elapsed).rounded(.up)))
    }

    static func allows(_ email: String, now: Date = Date()) -> Bool {
        secondsRemaining(for: email, now: now) == 0
    }

    /// Called after a send actually succeeds. A refused or failed send costs
    /// nobody an email, so it does not start a wait.
    static func record(_ email: String, now: Date = Date()) {
        var entries = log
        // Drop anything already expired, so this never grows into a long record
        // of addresses typed on this phone.
        let cutoff = now.timeIntervalSince1970 - cooldown
        entries = entries.filter { $0.value > cutoff }
        entries[fingerprint(email)] = now.timeIntervalSince1970
        log = entries
    }

    /// Tests only.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
