import Foundation
import Combine
import Network

/// Paper List Mode: the app stops talking to servers entirely.
///
/// The important word is *entirely*. Not "tries and fails" — does not attempt.
/// An app that keeps trying on a dead network is worse than one that stops:
/// every attempt is a hang, a spinner, a frozen tap, and a battery you need to
/// get home on.
///
/// Entered only by explicit user confirmation. Never automatic — dropping into
/// it silently would leave you unsure whether the rest of your household can
/// see what you're doing.
@MainActor
final class PaperMode: ObservableObject {
    static let shared = PaperMode()

    private static let defaultsKey = "paperModeActive"

    /// Survives relaunch on purpose: if the app crashed at the store, it must
    /// come back up still in paper mode rather than trying the network again.
    @Published private(set) var isActive: Bool {
        didSet { UserDefaults.standard.set(isActive, forKey: Self.defaultsKey) }
    }

    /// Set while paper mode is on and the network has come back — the cue to
    /// gently offer a return to normal. Never acts on its own.
    @Published var networkLooksBack = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "PaperMode.reachability")

    private init() {
        isActive = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        startWatchingForNetwork()
    }

    func enter() {
        guard !isActive else { return }
        isActive = true
        networkLooksBack = false
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        networkLooksBack = false
    }

    /// Watches passively so the banner can offer a way back. Only ever sets a
    /// flag — it never reconnects on its own, because the user is mid-shop and
    /// gets to decide when the app starts talking again.
    ///
    /// Note this reports on the *interface*, not on whether requests actually
    /// succeed, so store wifi sitting behind a captive portal will look
    /// available. That's acceptable: the worst case is the user taps reconnect,
    /// it doesn't work, and they stay on paper.
    private func startWatchingForNetwork() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.networkLooksBack = (path.status == .satisfied)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    /// The single gate every network path checks. One choke point beats twenty
    /// scattered guards that drift apart over time.
    var blocksNetwork: Bool { isActive }
}

/// Thrown instead of making a request while paper mode is on. Callers treat it
/// as "skip quietly" — it is an expected outcome, not a failure to report.
struct PaperModeActive: Error {}
