import XCTest
import Amplify
@testable import GroceryApp

/// Deciding *why* a call failed used to be done by string-matching the
/// interpolated description of the error object:
///
/// ```swift
/// "\(error)".lowercased().contains("network")
/// ```
///
/// That guess was wrong in both directions. A perfectly ordinary server refusal
/// whose text happened to contain the word became "check your connection" to
/// somebody standing on full signal, and a genuine dropped socket that described
/// itself in other words became a sign-out. These tests pin the classification to
/// the error's *type* — the thing that is actually true about it — and pin the
/// wording rules that stopped "Invalid invite code Try again."
final class ServiceFailureTests: XCTestCase {

    /// Every case, so a rule stated about "the only one that..." is checked
    /// against all of them rather than the two somebody remembered.
    private let everyCase: [ServiceFailure] = [
        .offline,
        .unauthorized,
        .refused("You've used your allowance for today"),
        .server("The server fell over"),
        .malformed("Expected an id and got nothing")
    ]

    // MARK: - Classifying a thrown error

    func testAnErrorTheTransportRaisedItselfIsOffline() {
        XCTAssertEqual(ServiceFailure.from(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ServiceFailure.from(URLError(.timedOut)), .offline)
        XCTAssertEqual(ServiceFailure.from(URLError(.networkConnectionLost)), .offline)
    }

    /// The same failure arriving already bridged to `NSError` — which is how it
    /// reaches us once anything has caught and rethrown it.
    func testATransportErrorStillCountsOnceItIsAnNSError() {
        let bridged = NSError(domain: NSURLErrorDomain,
                              code: NSURLErrorNotConnectedToInternet,
                              userInfo: nil)
        XCTAssertEqual(ServiceFailure.from(bridged), .offline)
    }

    /// Amplify wraps. The old string match looked at the wrapper's description,
    /// which says nothing about the network, so a dropped socket inside an
    /// Amplify error read as a server fault and told the user to try again on a
    /// connection that could not carry the request.
    func testATransportErrorHidingInsideAWrapperIsStillOffline() {
        let wrapped = NSError(
            domain: "com.amazonaws.amplify",
            code: 42,
            userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)]
        )
        XCTAssertEqual(ServiceFailure.from(wrapped), .offline)
    }

    func testASocketLevelFailureIsOffline() {
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED), userInfo: nil)
        XCTAssertEqual(ServiceFailure.from(refused), .offline)
    }

    /// The other direction, and the one that signed people out: an error with
    /// nothing to do with the network must never be read as the network.
    func testAnUnrelatedErrorIsNotBlamedOnTheNetwork() {
        let unrelated = NSError(domain: "com.byteclub.grocery",
                                code: 7,
                                userInfo: [NSLocalizedDescriptionKey: "Could not parse the network response"])
        let failure = ServiceFailure.from(unrelated)

        XCTAssertFalse(failure.isOffline,
                       "The word 'network' in a message is not evidence about the connection")
        XCTAssertNotEqual(failure, .offline)
    }

    /// Errors travel back up through layers that call `from` again. Classifying
    /// a decision twice must not change it.
    func testAFailureThatHasAlreadyBeenClassifiedComesBackUnchanged() {
        for failure in everyCase {
            XCTAssertEqual(ServiceFailure.from(failure), failure)
        }
    }

    func testAnAuthFailureAsksForASignInRatherThanARetry() {
        XCTAssertEqual(ServiceFailure.from(AuthError.signedOut("", "")), .unauthorized)
        XCTAssertEqual(ServiceFailure.from(AuthError.sessionExpired("", "")), .unauthorized)
    }

    func testARejectedRequestIsUnauthorizedRatherThanAServerFault() throws {
        func response(_ status: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com")!,
                                          statusCode: status,
                                          httpVersion: nil,
                                          headerFields: nil))
        }

        XCTAssertEqual(ServiceFailure.from(APIError.httpStatusError(403, try response(403))), .unauthorized)
        XCTAssertEqual(ServiceFailure.from(APIError.httpStatusError(401, try response(401))), .unauthorized)
        XCTAssertNotEqual(ServiceFailure.from(APIError.httpStatusError(500, try response(500))), .unauthorized)
    }

    /// Amplify's own "the request never left" case, which is what the string
    /// matching was groping for all along.
    func testAmplifysNetworkErrorIsOffline() {
        XCTAssertEqual(ServiceFailure.from(APIError.networkError("Lost", nil, URLError(.timedOut))),
                       .offline)
    }

    // MARK: - What we tell somebody to do

    /// "Try again when you have signal" is only ever a true sentence for one of
    /// these. Said about any other failure it is a lie that wastes the user's
    /// time on a retry that cannot work.
    func testOnlyBeingOfflineMentionsSignal() {
        for failure in everyCase {
            let mentionsSignal = failure.advice.lowercased().contains("signal")
            XCTAssertEqual(mentionsSignal, failure == .offline,
                           "\(failure) advises about signal when it should not: '\(failure.advice)'")
        }
    }

    /// A refusal is the server's considered answer. An allowance that is spent
    /// does not become unspent on a second attempt, so there is nothing to say.
    func testARefusalOffersNoAdviceAtAll() {
        XCTAssertEqual(ServiceFailure.refused("You've used your allowance for today").advice, "")
    }

    func testEverythingElseOffersSomething() {
        for failure in everyCase where failure != .refused("You've used your allowance for today") {
            XCTAssertFalse(failure.advice.isEmpty, "\(failure) leaves the user with nothing to do")
        }
    }

    // MARK: - Making a whole sentence

    /// Server-supplied reasons arrive unpunctuated, and pasting advice straight
    /// onto one produced "Invalid invite code Try again."
    func testAnUnpunctuatedReasonGetsAFullStopBeforeTheAdvice() {
        XCTAssertEqual(ServiceFailure.server("x").sentence("Invalid invite code"),
                       "Invalid invite code. Try again.")
    }

    func testAReasonThatAlreadyEndsInPunctuationIsNotGivenASecondOne() {
        XCTAssertEqual(ServiceFailure.server("x").sentence("Invalid invite code."),
                       "Invalid invite code. Try again.")
        XCTAssertEqual(ServiceFailure.server("x").sentence("Are you sure?"),
                       "Are you sure? Try again.")
        XCTAssertEqual(ServiceFailure.server("x").sentence("That went badly!"),
                       "That went badly! Try again.")
    }

    func testTheTwoHalvesAreJoinedByExactlyOneSpace() {
        let sentence = ServiceFailure.offline.sentence("Couldn't save that")
        XCTAssertEqual(sentence, "Couldn't save that. Try again when you have signal.")
        XCTAssertFalse(sentence.contains("  "))
    }

    /// With nothing to advise there must be no gap left where the advice would
    /// have gone — a trailing space shows up as a stray gap in a toast.
    func testARefusalEndsAtTheReasonWithNoTrailingSpace() {
        let sentence = ServiceFailure.refused("Out of goes for today").sentence("Out of goes for today")

        XCTAssertEqual(sentence, "Out of goes for today.")
        XCTAssertFalse(sentence.hasSuffix(" "))
    }

    func testNoReasonLeavesJustTheAdvice() {
        XCTAssertEqual(ServiceFailure.offline.sentence(""), "Try again when you have signal.")
        XCTAssertEqual(ServiceFailure.offline.sentence("   "), "Try again when you have signal.")
    }

    func testAFailureCanDescribeItselfWithoutACallerSupplyingWords() {
        XCTAssertEqual(ServiceFailure.offline.sentence,
                       "No connection to the server. Try again when you have signal.")
        XCTAssertEqual(ServiceFailure.unauthorized.sentence,
                       "You're not signed in. Sign in again.")
    }

    /// Whatever the case, what a person is shown is a sentence — not a fragment
    /// and not two run together.
    func testEveryFailureShowsAsFinishedSentences() {
        for failure in everyCase {
            let text = failure.sentence
            XCTAssertFalse(text.isEmpty, "\(failure) shows the user nothing")
            XCTAssertTrue(".!?".contains(text.last!), "\(failure) reads as a fragment: '\(text)'")
            XCTAssertFalse(text.contains("  "), "\(failure) has a double space: '\(text)'")
        }
    }

    // MARK: - The one message we are allowed to match

    func testTheServersDuplicateAnswerIsRecognised() {
        XCTAssertTrue(ServiceFailure.refused("DUPLICATE_ITEM: Milk").saysDuplicate)
        XCTAssertTrue(ServiceFailure.server("Milk already exists on the list").saysDuplicate)
    }

    func testAnyOtherRefusalIsNotADuplicate() {
        XCTAssertFalse(ServiceFailure.refused("You've used your allowance for today").saysDuplicate)
        XCTAssertFalse(ServiceFailure.server("The server fell over").saysDuplicate)
    }

    /// A failed send is not the server saying the item is already there. Reading
    /// it that way would swallow the add and tell the user it was a duplicate.
    func testBeingOfflineIsNeverADuplicate() {
        XCTAssertFalse(ServiceFailure.offline.saysDuplicate)
        XCTAssertFalse(ServiceFailure.unauthorized.saysDuplicate)
    }

    /// `APIError.pluginError` used to fall through to `@unknown default` and come
    /// out `.server`, so a dropped socket Amplify had wrapped in a plugin error
    /// was reported as the server's fault — the exact misclassification this
    /// type exists to prevent. The compiler's exhaustiveness warning found it;
    /// nothing failing ever would have.
    func testAPluginErrorWrappingATransportFailureIsOffline() {
        let underlying = APIError.networkError("lost", nil, URLError(.networkConnectionLost))
        XCTAssertEqual(ServiceFailure.from(APIError.pluginError(underlying)), .offline)
    }

    func testAPluginErrorWrappingSomethingElseIsNotOffline() {
        let underlying = APIError.operationError("bad request", "fix it", nil)
        XCTAssertNotEqual(ServiceFailure.from(APIError.pluginError(underlying)), .offline)
    }
}
