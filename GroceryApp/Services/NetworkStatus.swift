import Foundation
import Combine
import Network

/// Whether the device has a usable network interface.
///
/// Replaces PaperMode, which modelled connectivity as a *mode* you entered with a
/// confirmation dialog. That was the wrong shape: it made offline mutually
/// exclusive with shopping, so the one moment it existed for — standing in a shop
/// with no signal — was the one moment you could not reach it. Being offline is a
/// condition, not a place you go.
///
/// This only reports on the interface, never on whether requests actually
/// succeed, so a captive portal looks satisfied. Use it to rule offline OUT (the
/// network is plainly fine, so that failure was something else) rather than to
/// rule it in — for that, ask whether requests are failing.
@MainActor
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()

    @Published private(set) var pathIsSatisfied = true

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "NetworkStatus.reachability")

    private init() {
        // One-time cleanup: builds up to v1.6.0 persisted a paper-mode flag that
        // survived relaunch by design. With the mode gone, anyone still carrying
        // it would otherwise be stuck in a state nothing can clear.
        UserDefaults.standard.removeObject(forKey: "paperModeActive")

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathIsSatisfied = (path.status == .satisfied)
            }
        }
        monitor.start(queue: monitorQueue)
    }
}

/// How to end a failure message, when the cause is not actually known.
///
/// Almost every `catch` in this app used to finish with "check your signal" or
/// "try again when you have signal". A `catch` catches everything — a validation
/// error, a permission problem, a bug of ours — so that sentence was a guess
/// dressed as a diagnosis, and it was wrong often enough that somebody standing
/// outside on 5G was told to check their connection for a name-matching bug.
///
/// The only thing the app genuinely knows is whether there is a network
/// interface at all. `pathIsSatisfied` says nothing about whether requests
/// succeed — a captive portal looks fine — so it is used to rule offline **in**,
/// never to rule it out: no interface is a fact worth stating, and everything
/// else gets a plain "try again".
enum FailureAdvice {
    @MainActor
    static var tryAgain: String {
        NetworkStatus.shared.pathIsSatisfied ? "Try again." : "Try again when you have signal."
    }

    /// Lower-case, for the end of a clause: "…nothing was changed — try again."
    @MainActor
    static var tryAgainClause: String {
        NetworkStatus.shared.pathIsSatisfied ? "try again" : "try again when you have signal"
    }
}
