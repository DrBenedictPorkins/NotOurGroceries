import Foundation
import Amplify
import AWSPluginsCore

/// Where the household stands against its allowances, as the server reports it.
///
/// Every number here comes from `householdAllowances`, caps included — the app
/// never hardcodes one. See MONETIZATION.qmd for what the allowances are and why.
struct AllowanceSummary: Equatable {
    enum Plan: String {
        case free = "FREE"
        case subscribed = "SUBSCRIBED"
        case comped = "COMPED"

        /// The word shown in Settings. Comped households are told so.
        var label: String {
            switch self {
            case .free: return "Free"
            case .subscribed: return "Subscribed"
            case .comped: return "Complimentary"
            }
        }
    }

    let plan: Plan
    /// Subscribed and not lapsed, or comped. When true no cap applies.
    let entitled: Bool
    let periodResetsAt: Date
    let placementsUsed: Int
    let placementsCap: Int
    let parsesUsed: Int
    let parsesCap: Int
    let membersCap: Int
    let itemsCap: Int

    var placementsLeft: Int { max(0, placementsCap - placementsUsed) }
    var parsesLeft: Int { max(0, parsesCap - parsesUsed) }

    var daysUntilReset: Int {
        max(1, Int(ceil(periodResetsAt.timeIntervalSinceNow / 86_400)))
    }

    /// The launch pop-up threshold: half or more of any recurring allowance gone.
    /// Early in the period the number is noise, and this app is opened several
    /// times a day to add one thing.
    /// The item count is not on this summary — items are written straight to the
    /// table and counted on the client — so it is passed in.
    ///
    /// Items were missing from this check entirely, and from the card. The only
    /// thing anyone ever saw about the 150-item cap was the refusal at the
    /// moment they hit it, with no earlier hint that it existed or that
    /// subscribing lifts it. Somebody restoring a trip met it as "nothing
    /// happened".
    func warrantsNudge(itemCount: Int) -> Bool {
        guard !entitled else { return false }
        return placementsUsed * 2 >= placementsCap
            || parsesUsed * 2 >= parsesCap
            || itemCount * 2 >= itemsCap
    }
}

/// Fetches and caches the household's allowances.
///
/// Refreshed on launch, on return to the foreground after a long background, when
/// the allowances page opens, and after anything metered succeeds. Checks that
/// gate an action read the cache; the server is what actually refuses.
@MainActor
final class AllowanceService: ObservableObject {
    static let shared = AllowanceService()

    @Published private(set) var summary: AllowanceSummary?
    private(set) var lastRefreshed: Date?

    /// Set by a fresh sign-in or sign-up; consumed by the first launch card
    /// check after it. Shows the card once whatever the usage — a restored
    /// session never sets it, so launches keep the half-used threshold.
    var showOnNextAppearance = false

    /// The gate for the whole import feature — speak, camera, photos, paste, and
    /// dictation at the store. Checked at the entry point, not at the API call:
    /// a person who is out of imports is stopped at the Import icon, not after
    /// recording a list that then cannot be parsed.
    var importsExhausted: Bool {
        guard let s = summary else { return false }
        return !s.entitled && s.parsesLeft == 0
    }

    /// Refresh without holding anything up. Fired whenever a metered feature is
    /// opened, so the cache is at most one action stale.
    func refreshInBackground() {
        Task { await refresh() }
    }

    /// The server puts this in front of an error when an allowance is spent. The
    /// wording lives on each screen, not in the message.
    static let exhaustedPrefix = "ALLOWANCE_EXHAUSTED:"

    static func isExhausted(_ error: Error) -> Bool {
        if let graphQL = error as? GraphQLResponseError<JSONValue>,
           case .error(let errors) = graphQL {
            return errors.contains { $0.message.contains(exhaustedPrefix) }
        }
        return "\(error)".contains(exhaustedPrefix)
    }

    private init() {}

    func refresh() async {
        let document = """
        query HouseholdAllowances {
            householdAllowances {
                entitlement
                entitled
                periodResetsAt
                placementsUsed
                placementsCap
                parsesUsed
                parsesCap
                membersCap
                itemsCap
            }
        }
        """
        let request = GraphQLRequest<JSONValue>(
            document: document,
            variables: nil,
            responseType: JSONValue.self,
            authMode: AWSAuthorizationType.amazonCognitoUserPools
        )

        do {
            let response = try await Amplify.API.query(request: request)
            guard case .success(let json) = response,
                  case .object(let root) = json,
                  case .object(let node) = root["householdAllowances"],
                  let parsed = Self.decode(node) else { return }
            summary = parsed
            lastRefreshed = Date()
        } catch {
            // Nothing gates on a stale value that the server does not gate on
            // again. Worth a line, not an alert.
            print("Could not load allowances: \(error)")
        }
    }

    private static func decode(_ node: [String: JSONValue]) -> AllowanceSummary? {
        func int(_ key: String) -> Int? {
            if case .number(let n) = node[key] { return Int(n) }
            return nil
        }
        guard case .string(let planRaw) = node["entitlement"],
              let plan = AllowanceSummary.Plan(rawValue: planRaw),
              case .boolean(let entitled) = node["entitled"],
              case .string(let resetsRaw) = node["periodResetsAt"],
              let resets = ISO8601DateFormatter.withFractionalSeconds.date(from: resetsRaw)
                ?? ISO8601DateFormatter().date(from: resetsRaw),
              let placementsUsed = int("placementsUsed"), let placementsCap = int("placementsCap"),
              let parsesUsed = int("parsesUsed"), let parsesCap = int("parsesCap"),
              let membersCap = int("membersCap"), let itemsCap = int("itemsCap")
        else { return nil }

        return AllowanceSummary(
            plan: plan, entitled: entitled, periodResetsAt: resets,
            placementsUsed: placementsUsed, placementsCap: placementsCap,
            parsesUsed: parsesUsed, parsesCap: parsesCap,
            membersCap: membersCap, itemsCap: itemsCap
        )
    }
}

private extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
