import XCTest
@testable import GroceryApp

/// `AWSDateTime` arrives in two shapes and both have to parse.
///
/// Lambdas write `new Date().toISOString()`, which always carries milliseconds.
/// A bare `ISO8601DateFormatter` rejects those and returns nil, and every call
/// site in `AmplifyService` read that nil as "no date". The invite screen showed
/// no expiry, member rows showed no joined date, and `regenerateInviteCode` —
/// which makes the parse a required binding — threw every single time, so the
/// button appeared to do nothing at all.
///
/// The deprecated `createHousehold` wrote timestamps *without* a fraction, so
/// rows of both shapes exist in the live table and both must keep working.
@MainActor
final class AWSDateTimeTests: XCTestCase {

    func testParsesTheFractionalFormLambdasWrite() {
        // The literal value that sat in the live Household row and broke the screen.
        let parsed = AmplifyService.parseAWSDateTime("2026-01-19T17:45:23.896Z")
        XCTAssertNotNil(parsed, "Millisecond precision is what every Lambda writes")
    }

    func testParsesTheFractionlessFormTheAppUsedToWrite() {
        XCTAssertNotNil(AmplifyService.parseAWSDateTime("2026-01-19T17:45:23Z"),
                        "Rows written by the deprecated createHousehold have no fraction")
    }

    func testBothFormsOfTheSameInstantAgree() {
        let withFraction = AmplifyService.parseAWSDateTime("2026-01-19T17:45:23.000Z")
        let without      = AmplifyService.parseAWSDateTime("2026-01-19T17:45:23Z")
        XCTAssertEqual(withFraction, without)
    }

    func testFractionIsNotDiscarded() {
        let a = AmplifyService.parseAWSDateTime("2026-01-19T17:45:23.000Z")
        let b = AmplifyService.parseAWSDateTime("2026-01-19T17:45:23.896Z")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(b!.timeIntervalSince(a!), 0.896, accuracy: 0.001)
    }

    func testGarbageStillReturnsNil() {
        XCTAssertNil(AmplifyService.parseAWSDateTime(""))
        XCTAssertNil(AmplifyService.parseAWSDateTime("not a date"))
        XCTAssertNil(AmplifyService.parseAWSDateTime("2026-13-45T99:99:99Z"))
    }

    /// What we write has to be readable by what we read — the round trip is the
    /// part that silently rotted, since writer and reader were configured apart.
    func testRoundTrip() {
        let original = Date(timeIntervalSince1970: 1_768_844_723.896)
        let text = AmplifyService.formatAWSDateTime(original)
        let back = AmplifyService.parseAWSDateTime(text)

        XCTAssertNotNil(back)
        XCTAssertEqual(back!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)
    }

    func testWeWriteTheFormLambdasAlsoWrite() {
        let text = AmplifyService.formatAWSDateTime(Date(timeIntervalSince1970: 1_768_844_723.896))
        XCTAssertTrue(text.hasSuffix("Z"))
        XCTAssertTrue(text.contains("."), "Milliseconds are what the backend emits; match it")
    }

    /// An expired code has to compare as expired. This is the comparison the
    /// invite screen makes, and while the parse returned nil it never ran at all.
    func testAnExpiredCodeComparesAsExpired() {
        let expired = AmplifyService.parseAWSDateTime("2026-01-19T17:45:23.896Z")
        XCTAssertNotNil(expired)
        XCTAssertLessThan(expired!, Date(), "January 2026 is in the past; the screen must say so")
    }
}
