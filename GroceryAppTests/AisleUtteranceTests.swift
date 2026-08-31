import XCTest
@testable import GroceryApp

/// The parser behind aisle capture. All of it runs offline with no recogniser and
/// no network, which is the whole reason it is a regular expression and not a
/// model call — these tests are the proof of that.
final class AisleUtteranceTests: XCTestCase {

    /// ShopRite as it actually stands: captured numbers plus standard departments.
    private var layout: [StoreAisle] {
        var aisles = (1...15).map {
            StoreAisle(id: "aisle-\($0)", number: "\($0)", name: "", displayOrder: $0)
        }
        aisles.append(StoreAisle(id: "standard-dairy", number: "", name: "Dairy & Eggs", displayOrder: 900))
        aisles.append(StoreAisle(id: "standard-produce", number: "", name: "Produce", displayOrder: 901))
        aisles.append(StoreAisle(id: "standard-personal", number: "", name: "Personal Care", displayOrder: 902))
        return aisles
    }

    // MARK: - Number words

    func testNumberWordsBecomeDigits() {
        let expected: [String: String] = [
            "zero": "0", "one": "1", "nine": "9", "ten": "10",
            "eleven": "11", "fifteen": "15", "sixteen": "16",
            "nineteen": "19", "twenty": "20", "thirty": "30",
        ]
        for (word, digits) in expected {
            XCTAssertEqual(AisleUtterance.normalise(word), digits, "\(word) should be \(digits)")
        }
    }

    func testCompoundNumberWords() {
        XCTAssertEqual(AisleUtterance.normalise("twenty four"), "24")
        XCTAssertEqual(AisleUtterance.normalise("thirty one"), "31")
    }

    /// "sixteen" and "16" have to land on one aisle. If they diverge a store
    /// quietly grows a `16` and a `Sixteen` with half the items in each.
    func testSpokenAndTypedNumbersAgree() {
        let spoken = AisleUtterance.resolve("aisle sixteen", in: layout)
        let typed = AisleUtterance.resolve("16", in: layout)
        XCTAssertEqual(spoken, typed)
    }

    // MARK: - Stripping and cutting

    func testAislePrefixIsStripped() {
        for phrase in ["aisle 16", "Aisle 16", "in aisle 16", "it's in aisle 16", "16"] {
            XCTAssertEqual(AisleUtterance.normalise(phrase), "16", "failed on \(phrase)")
        }
    }

    /// Position within an aisle is not captured: no plaque prints it, a manager
    /// can move a bay, and the shopper is standing right there.
    func testEverythingAfterACommaIsDropped() {
        XCTAssertEqual(AisleUtterance.normalise("international, middle"), "International")
        XCTAssertEqual(AisleUtterance.normalise("aisle 7, near the back"), "7")
    }

    func testNamesAreTitleCased() {
        XCTAssertEqual(AisleUtterance.normalise("beer garden"), "Beer Garden")
        XCTAssertEqual(AisleUtterance.normalise("WINE & SPIRITS"), "Wine & Spirits")
    }

    // MARK: - Resolving against the store

    func testExistingNumberedAisleIsReused() {
        guard case .existing(let aisle) = AisleUtterance.resolve("aisle twelve", in: layout) else {
            return XCTFail("aisle 12 already exists and should have matched")
        }
        XCTAssertEqual(aisle.number, "12")
    }

    /// Standing at the cabinet you say "dairy", not "Dairy & Eggs".
    func testLooseNameMatchFindsTheDepartment() {
        guard case .existing(let aisle) = AisleUtterance.resolve("dairy", in: layout) else {
            return XCTFail("should have resolved to the existing Dairy & Eggs")
        }
        XCTAssertEqual(aisle.id, "standard-dairy")
    }

    func testUnknownNumberCreatesANumberedAisle() {
        guard case .new(let number, let name) = AisleUtterance.resolve("aisle sixteen", in: layout) else {
            return XCTFail("16 is not in this layout and should be new")
        }
        XCTAssertEqual(number, "16")
        XCTAssertEqual(name, "")
    }

    func testUnknownNameCreatesANamedAisle() {
        guard case .new(let number, let name) = AisleUtterance.resolve("artisan cheeses", in: layout) else {
            return XCTFail("should be a new named aisle")
        }
        XCTAssertEqual(number, "")
        XCTAssertEqual(name, "Artisan Cheeses")
    }

    /// Saying the same thing twice must not leave the store with two aisle 16s.
    func testSecondCaptureOfTheSameAisleMatchesTheFirst() {
        guard case .new(let number, let name) = AisleUtterance.resolve("sixteen", in: layout) else {
            return XCTFail("first capture should be new")
        }
        var grown = layout
        grown.append(StoreAisle(id: "aisle-16", number: number, name: name, displayOrder: 16))

        guard case .existing = AisleUtterance.resolve("aisle sixteen", in: grown) else {
            return XCTFail("second capture should reuse the aisle the first one made")
        }
    }

    // MARK: - Rejection

    func testEmptyInputIsRejected() {
        guard case .rejected = AisleUtterance.resolve("   ", in: layout) else {
            return XCTFail("blank input should be rejected, not saved")
        }
    }

    /// Whisper-style filler and general rambling are not aisles.
    func testASentenceIsRejected() {
        let rambling = "erm I think it was somewhere near the back by the tills"
        guard case .rejected = AisleUtterance.resolve(rambling, in: layout) else {
            return XCTFail("a sentence should be rejected rather than becoming an aisle")
        }
    }

    func testAisleWordOnItsOwnIsRejected() {
        guard case .rejected = AisleUtterance.resolve("aisle", in: layout) else {
            return XCTFail("'aisle' with no number is nothing to save")
        }
    }
}
