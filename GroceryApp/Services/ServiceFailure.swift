import Foundation
import Amplify
import AWSPluginsCore

/// Why a call to the backend did not do what was asked.
///
/// Before this existed there was no type for it. Five error enums in this app
/// and not one had a case meaning "the network was unavailable", so the only way
/// anyone could ask that question was:
///
/// ```swift
/// let text = "\(error)".lowercased()
/// return text.contains("network") || text.contains("offline")
/// ```
///
/// — string-matching the interpolated description of an error object. Every
/// wrong guess became a message telling somebody on full signal to check their
/// connection, and the layer above compensated by *counting* failures to infer
/// what the error should simply have said.
///
/// Amplify makes this worse by having two failure channels for one call: a
/// thrown error, and a returned `GraphQLResponse.failure`. Half the call sites
/// handled one and missed the other. `API` below collapses both into this.
enum ServiceFailure: LocalizedError, Equatable {
    /// The request never reached the server. Airplane mode, no bars, a dropped
    /// socket, a timeout. The only case where "try again when you have signal"
    /// is a true sentence.
    case offline

    /// The token is missing, expired or lacks the group claim. Retrying will
    /// fail identically forever; this needs a sign-in, not a second attempt.
    case unauthorized

    /// The server understood and said no on purpose — an allowance is spent, an
    /// item is locked, a condition failed. Not a fault, and never "try again".
    case refused(String)

    /// The server answered with an error of its own.
    case server(String)

    /// It answered, and the answer was not the shape we asked for. Ours to fix,
    /// not the user's to retry.
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .offline: return "No connection to the server."
        case .unauthorized: return "You're not signed in."
        case .refused(let why): return why
        case .server(let why): return why
        case .malformed(let what): return what
        }
    }

    /// What to tell somebody to do, given this actually happened. Empty when
    /// there is nothing useful to say.
    ///
    /// `.refused` gets nothing on purpose. The server understood and said no —
    /// an allowance is spent, an item is locked — and telling somebody to try
    /// again is telling them to do a thing that cannot work. The refusal already
    /// carries its own explanation; that is the whole message.
    var advice: String {
        switch self {
        case .offline: return "Try again when you have signal."
        case .unauthorized: return "Sign in again."
        case .refused: return ""
        case .server, .malformed: return "Try again."
        }
    }

    /// A whole sentence: what happened, then what to do, joined properly.
    ///
    /// Server-supplied reasons arrive without terminal punctuation, so pasting
    /// advice onto one produced "Invalid invite code Try again." Everything that
    /// shows a failure to a person should come through here rather than
    /// interpolating the two halves by hand.
    func sentence(_ what: String) -> String {
        let trimmed = what.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return advice }
        let stopped = ".!?".contains(trimmed.last!) ? trimmed : trimmed + "."
        return advice.isEmpty ? stopped : "\(stopped) \(advice)"
    }

    /// The failure's own description, made into a sentence.
    var sentence: String {
        sentence(errorDescription ?? "Something went wrong")
    }

    var isOffline: Bool { self == .offline }

    /// The server saying this item is already on the list.
    ///
    /// Matching a message is legitimate here and nowhere else: this string is a
    /// protocol between our own `addItemFunction` and this client, versioned
    /// with them. That is a different thing from guessing whether somebody
    /// else's error object was about the network, which is what this type
    /// exists to stop.
    var saysDuplicate: Bool {
        switch self {
        case .refused(let why), .server(let why):
            return why.contains("DUPLICATE_ITEM") || why.contains("already exists")
        default:
            return false
        }
    }

    // MARK: - Classifying what Amplify hands us

    /// Map a thrown error onto this. Everything here matches on a *type* or a
    /// declared case — never on the text of a description.
    static func from(_ error: Error) -> ServiceFailure {
        if let failure = error as? ServiceFailure { return failure }

        // The transport said so itself. This is the case the string matching
        // was groping for all along.
        if let apiError = error as? APIError {
            switch apiError {
            case .networkError:
                return .offline
            case .operationError(let description, _, let underlying):
                if let underlying, isTransport(underlying) { return .offline }
                return .server(description)
            case .httpStatusError(let status, _):
                return status == 401 || status == 403 ? .unauthorized : .server("Server error \(status).")
            case .invalidConfiguration(let description, _, _),
                 .invalidURL(let description, _, _),
                 .unknown(let description, _, _):
                if isTransport(apiError.underlyingError) { return .offline }
                return .server(description)
            case .pluginError(let underlying):
                // Amplify wraps some transport failures in a plugin error, so
                // this fell to `@unknown default` and came out `.server` — a
                // dropped socket reported as the server's fault, which is the
                // exact misclassification this type exists to stop. Found by the
                // compiler's exhaustiveness warning, not by anything failing.
                //
                // Recursed rather than passed to `isTransport`, because the
                // wrapped thing is frequently another `APIError` whose own cause
                // is an associated value — `isTransport` only walks
                // `NSUnderlyingErrorKey`, so it looks straight past it and the
                // fix would have been no fix at all. Caught by its own test.
                return from(underlying)
            @unknown default:
                return .server(apiError.errorDescription)
            }
        }

        if let authError = error as? AuthError {
            switch authError {
            case .signedOut, .sessionExpired, .notAuthorized:
                return .unauthorized
            case .service(let description, _, let underlying):
                if let underlying, isTransport(underlying) { return .offline }
                return .server(description)
            default:
                return isTransport(error) ? .offline : .server(authError.errorDescription)
            }
        }

        if isTransport(error) { return .offline }
        return .server(error.localizedDescription)
    }

    /// GraphQL answered, but with errors rather than data.
    ///
    /// The allowance Lambdas refuse by throwing a message with a known prefix,
    /// which is a deliberate protocol between our server and our client — not a
    /// guess about somebody else's error text.
    static func from(graphQLErrors errors: [GraphQLError]) -> ServiceFailure {
        let joined = errors.map(\.message).joined(separator: "; ")

        if errors.contains(where: { $0.message.hasPrefix(Self.allowanceExhaustedPrefix) }) {
            return .refused(joined.replacingOccurrences(of: Self.allowanceExhaustedPrefix, with: ""))
        }
        if errors.contains(where: {
            $0.message.contains("Unauthorized") || $0.message.contains("Not Authorized")
        }) {
            return .unauthorized
        }
        return .server(joined.isEmpty ? "The server rejected that." : joined)
    }

    /// Matches `EXHAUSTED_PREFIX` in `amplify/data/allowance.ts`.
    static let allowanceExhaustedPrefix = "ALLOWANCE_EXHAUSTED:"

    /// A transport-level failure, by type. `URLError` covers not-connected,
    /// timed-out, network-connection-lost, cannot-find-host and the rest;
    /// `POSIXError` covers the socket-level equivalents.
    private static func isTransport(_ error: Error?) -> Bool {
        guard let error else { return false }
        if error is URLError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return true }
        if nsError.domain == NSPOSIXErrorDomain {
            return [ECONNRESET, ECONNREFUSED, ENETDOWN, ENETUNREACH, EHOSTUNREACH, ETIMEDOUT]
                .contains(Int32(nsError.code))
        }
        // Amplify wraps; look one level down rather than at the description.
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTransport(underlying)
        }
        return false
    }
}

/// The one way this app talks to AppSync.
///
/// Returns the data, or throws a `ServiceFailure`. There is no second channel
/// and no `GraphQLResponse` for a caller to forget to switch on — that shape is
/// what let a failed mutation look like a successful one at half the call sites.
enum API {
    /// Reads, with retries.
    ///
    /// iOS tears down sockets while the app is suspended, so the first request
    /// after coming back very often fails on a perfectly healthy connection.
    /// Retrying here means every caller gets it and the layers above only ever
    /// see failures that survived three attempts.
    static func query(_ request: GraphQLRequest<JSONValue>) async throws -> JSONValue {
        let delays: [UInt64] = [400_000_000, 1_200_000_000]
        var lastFailure: ServiceFailure = .offline

        for attempt in 0...delays.count {
            do {
                return try unwrap(try await Amplify.API.query(request: request))
            } catch let failure as ServiceFailure {
                // A refusal is the server's considered answer and an expired
                // token fails identically forever. Neither improves with a
                // second go, and retrying delays the sign-in that is actually
                // needed.
                switch failure {
                case .unauthorized, .refused, .malformed: throw failure
                case .offline, .server: lastFailure = failure
                }
                if attempt < delays.count {
                    try? await Task.sleep(nanoseconds: delays[attempt])
                }
            }
        }
        throw lastFailure
    }

    /// Writes are not retried here. A mutation that may have been applied and
    /// whose reply was lost must not be replayed blindly; the outbox and
    /// `finishShopping`'s `tripId` are how repeats are made safe, deliberately
    /// and per call site.
    static func mutate(_ request: GraphQLRequest<JSONValue>) async throws -> JSONValue {
        try unwrap(try await Amplify.API.mutate(request: request))
    }

    /// For the one caller that needs the raw envelope back.
    ///
    /// `mutate` above throws away `.partial` and `.transformationError`, which is
    /// right almost everywhere and wrong for `parseIngredients`: that Lambda
    /// returns a JSON string, so a payload that arrived perfectly intact
    /// routinely fails Amplify's shape check and surfaces as one of those two.
    /// Discarding them would break long-text and photo imports.
    ///
    /// Anything that is genuinely a failure still throws a `ServiceFailure`;
    /// only the recoverable-body cases come back for the caller to salvage.
    static func mutateRecoveringPartials(
        _ request: GraphQLRequest<JSONValue>
    ) async throws -> GraphQLResponse<JSONValue> {
        do {
            return try await Amplify.API.mutate(request: request)
        } catch {
            throw ServiceFailure.from(error)
        }
    }

    private static func unwrap(_ response: GraphQLResponse<JSONValue>) throws -> JSONValue {
        switch response {
        case .success(let value):
            return value
        case .failure(let error):
            switch error {
            case .error(let errors), .partial(_, let errors):
                throw ServiceFailure.from(graphQLErrors: errors)
            case .transformationError(_, let apiError):
                throw ServiceFailure.from(apiError)
            case .unknown(let description, _, _):
                throw ServiceFailure.server(description)
            }
        }
    }
}
