import Foundation

/// What this copy of the app is, said the same way everywhere.
///
/// Read in three places — Settings, the loading screen, and the Stores header —
/// each with its own copy of the same two `infoDictionary` lookups.
enum AppVersion {

    /// The marketing version, e.g. "1.8.0".
    static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// The build number, or "dev".
    ///
    /// `CURRENT_PROJECT_VERSION` is `0` in the repo on purpose — CI stamps a
    /// datetime into it when it ships to TestFlight, and nothing sets it by hand.
    /// So a build made on somebody's Mac genuinely is build 0, and printing that
    /// reads as a version number that failed to fill in. "dev" says what it
    /// actually is. A TestFlight build has a real number and shows it.
    static var build: String {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return raw == "0" ? "dev" : raw
    }

    /// "v1.8.0 (dev)" or "v1.8.0 (202609031124)".
    static var full: String { "v\(marketing) (\(build))" }
}
