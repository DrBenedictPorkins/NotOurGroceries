import Foundation
import SwiftUI

/// One visible step of the launch handshake.
///
/// Every network call the app makes before it is usable is one of these. The
/// list used to stop at `syncingLists` and the rest — items, stores, whether a
/// trip is running, what this household is still allowed to do — ran after the
/// splash had already gone, so they landed on screen minutes later on a slow
/// connection with nothing to explain them. If a call blocks the app being
/// useful, it belongs here where it can be watched.
enum LoadingStep: Int, CaseIterable {
    case initializing = 0
    case configuringServices = 1
    case validatingLogin = 2
    /// One call now, not six. See `HandshakeService` for why.
    case syncing = 3
    case ready = 4

    var description: String {
        switch self {
        case .initializing: return "Starting up..."
        case .configuringServices: return "Connecting to servers..."
        case .validatingLogin: return "Checking your sign-in..."
        case .syncing: return "Getting your list..."
        case .ready: return "Ready!"
        }
    }

    /// What is missing if this step is skipped. A noun phrase, because it is
    /// read inside a sentence — `description` is a sentence of its own and
    /// produced "Couldn't load Checking your sign-in...." when it was used here.
    var skippedDescription: String {
        switch self {
        case .initializing, .ready: return "part of the startup"
        case .configuringServices: return "the connection to the server"
        case .validatingLogin: return "your sign-in"
        case .syncing: return "your list"
        }
    }

    /// What walking away from this step actually costs, said before the person
    /// decides. "Continue anyway" on its own promises nothing and warns of
    /// nothing; most of these steps are genuinely safe to skip because the app
    /// keeps the last good copy on disk, and one of them is not.
    var stallConsequence: String {
        switch self {
        case .configuringServices, .validatingLogin:
            return "Without this you'll be asked to sign in again."
        case .syncing:
            return "Without this you'll see your last saved list, not the current one."
        case .initializing, .ready:
            return ""
        }
    }

    /// The skip button's words. Skipping the sign-in check does not continue
    /// into the app — there is nothing behind it but the sign-in screen — so it
    /// must not say it does.
    var skipButtonTitle: String {
        switch self {
        case .configuringServices, .validatingLogin: return "Sign in instead"
        default: return "Skip this step"
        }
    }

    var progress: Double {
        Double(rawValue) / Double(LoadingStep.allCases.count - 1)
    }
}

/// Represents an error that occurred during loading
struct AppError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let details: String
    let timestamp: Date
    let step: LoadingStep

    var formattedDetails: String {
        """
        Error: \(title)
        Step: \(step.description)
        Time: \(timestamp.formatted())

        Message:
        \(message)

        Technical Details:
        \(details)
        """
    }
}

/// Manages the app's loading state and error handling
@MainActor
class AppLoadingState: ObservableObject {
    static let shared = AppLoadingState()

    @Published private(set) var currentStep: LoadingStep = .initializing
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var isReady: Bool = false
    @Published var error: AppError?

    /// Set when a step has been running longer than its deadline. The splash
    /// names it and hands the decision over rather than spinning forever, which
    /// is what a dropped connection used to produce: a progress bar that never
    /// moved again and no way past it but force-quitting.
    @Published private(set) var stalledStep: LoadingStep?

    /// Steps the person chose to walk away from, so the splash can say what it
    /// did not get instead of pretending the launch was clean.
    @Published private(set) var skippedSteps: [LoadingStep] = []

    /// True once the auth half of the handshake is done. `ContentView` owns the
    /// second half — it owns the view model the second half writes into — and
    /// waits on this so the two halves do not run at once and fight over the
    /// step label.
    @Published private(set) var phaseOneComplete: Bool = false

    /// Set when the session check has failed and this phone is carrying a list.
    /// Not a stall — the common failure is fast, not slow, and hanging the offer
    /// off the eight-second deadline meant it never appeared at all.
    @Published private(set) var offeringOffGrid = false

    /// A step that failed outright, as opposed to one that is merely slow.
    ///
    /// A fault is not a condition. Being offline is something the app is built to
    /// carry on through; an unreadable or rejected answer means we do not know
    /// what the server thinks, and carrying on would put somebody in a list
    /// assembled from a stale local file with a banner apologising for it — the
    /// exact half-loaded state one call was supposed to end.
    @Published private(set) var failedStep: LoadingStep?
    @Published private(set) var failureReason: String?

    var isAskingSomething: Bool {
        stalledStep != nil || offeringOffGrid || failedStep != nil
    }

    enum StallDecision { case retry, skip }
    private var stallDecision: CheckedContinuation<StallDecision, Never>?

    /// How long a step may run before the splash admits it is stuck.
    static let stepTimeout: TimeInterval = 8

    private init() {}

    func setStep(_ step: LoadingStep) {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentStep = step
            if step == .ready {
                isReady = true
                // Don't auto-dismiss - wait for user to tap button
            }
        }
    }

    func markPhaseOneComplete() {
        phaseOneComplete = true
    }

    /// Blocks until the auth half has finished. Polled rather than signalled
    /// because the waiter is a view task that may be created before or after the
    /// flag is set, and a missed signal would hang the launch.
    func waitForPhaseOne() async {
        while !phaseOneComplete {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Running a step

    /// Runs one step of the handshake with the step name on screen and a
    /// deadline behind it.
    ///
    /// The work keeps running after a skip on purpose: a slow reply that arrives
    /// two minutes later is still the right data, and cancelling it would only
    /// guarantee the screen stays wrong.
    func perform(_ step: LoadingStep,
                 timeout: TimeInterval = AppLoadingState.stepTimeout,
                 _ work: @escaping @MainActor () async -> Void) async {
        setStep(step)

        final class Flag { var done = false }

        while true {
            // A fresh flag per attempt, so a retried step is never satisfied by
            // the attempt it replaced finishing late.
            let flag = Flag()
            let job = Task { @MainActor in
                await work()
                flag.done = true
            }

            let deadline = Date().addingTimeInterval(timeout)
            while !flag.done && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if flag.done { return }

            stalledStep = step
            let decision = await withCheckedContinuation { (c: CheckedContinuation<StallDecision, Never>) in
                stallDecision = c
            }
            stalledStep = nil

            // It may well have arrived while the question was on screen.
            if flag.done { return }

            if decision == .skip {
                skippedSteps.append(step)
                return
            }
            job.cancel()
        }
    }

    /// Offer off-grid and wait. `.skip` means go off-grid, `.retry` means try
    /// the session check again.
    func askAboutOffGrid() async -> StallDecision {
        offeringOffGrid = true
        let decision = await withCheckedContinuation { (c: CheckedContinuation<StallDecision, Never>) in
            stallDecision = c
        }
        offeringOffGrid = false
        return decision
    }

    /// Stop and ask. `.retry` runs the step again, `.skip` carries on knowingly.
    func askAboutFailure(_ step: LoadingStep, _ failure: ServiceFailure) async -> StallDecision {
        failedStep = step
        failureReason = failure.errorDescription
        let decision = await withCheckedContinuation { (c: CheckedContinuation<StallDecision, Never>) in
            stallDecision = c
        }
        failedStep = nil
        failureReason = nil
        if decision == .skip { skippedSteps.append(step) }
        return decision
    }

    func resolveStall(_ decision: StallDecision) {
        guard let c = stallDecision else { return }
        stallDecision = nil
        c.resume(returning: decision)
    }

    /// What did not load, phrased for a person. Nil when the launch was clean.
    var skippedSummary: String? {
        guard !skippedSteps.isEmpty else { return nil }
        let names = skippedSteps.map(\.skippedDescription)
        let joined: String
        switch names.count {
        case 1: joined = names[0]
        case 2: joined = "\(names[0]) and \(names[1])"
        default: joined = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        // Off-grid is not a failure to report, it is where we are going. The
        // list screen says so from the moment it appears.
        if AmplifyService.shared.isOffGrid { return nil }

        // "Pull down on your list" is useless advice to somebody who is about to
        // be shown a sign-in screen, because there is no list to pull down on.
        if skippedSteps.contains(.validatingLogin) || skippedSteps.contains(.configuringServices) {
            return "Couldn't check \(joined). \(FailureAdvice.tryAgain)"
        }
        return "Couldn't load \(joined). Pull down on your list to try again."
    }

    func wasSkipped(_ step: LoadingStep) -> Bool {
        skippedSteps.contains(step)
    }

    func dismissSplash() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isLoading = false
        }
    }

    func reportError(title: String, message: String, details: String = "") {
        error = AppError(
            title: title,
            message: message,
            details: details,
            timestamp: Date(),
            step: currentStep
        )
    }

    func clearError() {
        error = nil
    }

    func reset() {
        currentStep = .initializing
        isLoading = true
        isReady = false
        error = nil
        stalledStep = nil
        skippedSteps = []
        phaseOneComplete = false
    }
}
