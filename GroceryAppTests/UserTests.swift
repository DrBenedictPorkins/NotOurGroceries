import XCTest
@testable import GroceryApp

final class UserTests: XCTestCase {

    // MARK: - Initialization Tests

    func testUser_DefaultInitialization_SetsDefaultValues() {
        // Given / When
        let user = User(email: "test@example.com", displayName: "Test User")

        // Then
        XCTAssertFalse(user.id.isEmpty, "Should generate a non-empty ID")
        XCTAssertEqual(user.email, "test@example.com")
        XCTAssertEqual(user.displayName, "Test User")
        XCTAssertNil(user.avatarUrl, "Should default avatarUrl to nil")
        XCTAssertNil(user.householdId, "Should default householdId to nil")
        XCTAssertNotNil(user.createdAt, "Should set createdAt to current date")
        XCTAssertNotNil(user.lastActive, "Should set lastActive to current date")
    }

    func testUser_WithAllParameters_SetsAllValues() {
        // Given
        let id = "user123"
        let email = "john@example.com"
        let displayName = "John Doe"
        let avatarUrl = "https://example.com/avatar.jpg"
        let householdId = "household456"
        let createdAt = Date(timeIntervalSince1970: 1000000)
        let lastActive = Date(timeIntervalSince1970: 2000000)

        // When
        let user = User(
            id: id,
            email: email,
            displayName: displayName,
            avatarUrl: avatarUrl,
            householdId: householdId,
            createdAt: createdAt,
            lastActive: lastActive
        )

        // Then
        XCTAssertEqual(user.id, id)
        XCTAssertEqual(user.email, email)
        XCTAssertEqual(user.displayName, displayName)
        XCTAssertEqual(user.avatarUrl, avatarUrl)
        XCTAssertEqual(user.householdId, householdId)
        XCTAssertEqual(user.createdAt, createdAt)
        XCTAssertEqual(user.lastActive, lastActive)
    }

    func testUser_WithoutHouseholdId_AllowsNil() {
        // Given / When
        let user = User(
            email: "test@example.com",
            displayName: "Test User",
            householdId: nil
        )

        // Then
        XCTAssertNil(user.householdId)
    }

    func testUser_WithoutAvatarUrl_AllowsNil() {
        // Given / When
        let user = User(
            email: "test@example.com",
            displayName: "Test User",
            avatarUrl: nil
        )

        // Then
        XCTAssertNil(user.avatarUrl)
    }

    // MARK: - Mutable Property Tests

    func testUser_DisplayNameIsMutable() {
        // Given
        var user = User(email: "test@example.com", displayName: "Original Name")

        // When
        user.displayName = "Updated Name"

        // Then
        XCTAssertEqual(user.displayName, "Updated Name")
    }

    func testUser_AvatarUrlIsMutable() {
        // Given
        var user = User(email: "test@example.com", displayName: "Test User")

        // When
        user.avatarUrl = "https://example.com/new-avatar.jpg"

        // Then
        XCTAssertEqual(user.avatarUrl, "https://example.com/new-avatar.jpg")
    }

    func testUser_HouseholdIdIsMutable() {
        // Given
        var user = User(email: "test@example.com", displayName: "Test User")

        // When
        user.householdId = "household789"

        // Then
        XCTAssertEqual(user.householdId, "household789")
    }

    func testUser_LastActiveIsMutable() {
        // Given
        var user = User(email: "test@example.com", displayName: "Test User")
        let newDate = Date()

        // When
        user.lastActive = newDate

        // Then
        XCTAssertEqual(user.lastActive, newDate)
    }

    // MARK: - Codable Tests

    func testUser_Encodable_CanEncodeToJSON() throws {
        // Given
        let user = User(
            id: "user123",
            email: "john@example.com",
            displayName: "John Doe",
            avatarUrl: "https://example.com/avatar.jpg",
            householdId: "household456"
        )

        // When
        let encoder = JSONEncoder()
        let data = try encoder.encode(user)

        // Then
        XCTAssertFalse(data.isEmpty)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["id"] as? String, "user123")
        XCTAssertEqual(json?["email"] as? String, "john@example.com")
        XCTAssertEqual(json?["displayName"] as? String, "John Doe")
        XCTAssertEqual(json?["avatarUrl"] as? String, "https://example.com/avatar.jpg")
        XCTAssertEqual(json?["householdId"] as? String, "household456")
    }

    func testUser_Decodable_CanDecodeFromJSON() throws {
        // Given
        let json = """
        {
            "id": "user123",
            "email": "john@example.com",
            "displayName": "John Doe",
            "avatarUrl": "https://example.com/avatar.jpg",
            "householdId": "household456",
            "createdAt": "2024-01-01T10:00:00Z",
            "lastActive": "2024-01-02T15:30:00Z"
        }
        """

        // When
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        let user = try decoder.decode(User.self, from: data)

        // Then
        XCTAssertEqual(user.id, "user123")
        XCTAssertEqual(user.email, "john@example.com")
        XCTAssertEqual(user.displayName, "John Doe")
        XCTAssertEqual(user.avatarUrl, "https://example.com/avatar.jpg")
        XCTAssertEqual(user.householdId, "household456")
        XCTAssertNotNil(user.createdAt)
        XCTAssertNotNil(user.lastActive)
    }

    func testUser_Decodable_WithNullOptionalFields() throws {
        // Given
        let json = """
        {
            "id": "user123",
            "email": "john@example.com",
            "displayName": "John Doe",
            "createdAt": "2024-01-01T10:00:00Z",
            "lastActive": "2024-01-02T15:30:00Z"
        }
        """

        // When
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        let user = try decoder.decode(User.self, from: data)

        // Then
        XCTAssertNil(user.avatarUrl)
        XCTAssertNil(user.householdId)
    }

    // MARK: - Hashable Tests

    func testUser_Hashable_IdenticalUsersAreEqual() {
        // Given: Two users with identical properties
        let createdAt = Date()
        let user1 = User(id: "user123", email: "john@example.com", displayName: "John", createdAt: createdAt, lastActive: createdAt)
        let user2 = User(id: "user123", email: "john@example.com", displayName: "John", createdAt: createdAt, lastActive: createdAt)

        // Then: Users with identical properties should be equal
        // Note: User uses synthesized Equatable, comparing all stored properties
        XCTAssertEqual(user1, user2, "Users with identical properties should be equal")
    }

    func testUser_Hashable_DifferentIDsProduceDifferentEquality() {
        // Given
        let user1 = User(id: "user123", email: "john@example.com", displayName: "John")
        let user2 = User(id: "user456", email: "john@example.com", displayName: "John")

        // When / Then
        XCTAssertNotEqual(user1, user2, "Users with different IDs should not be equal")
    }

    func testUser_InSet_CanStoreUniqueUsers() {
        // Given: Two users with identical properties, and one different
        let createdAt = Date()
        let user1 = User(id: "user123", email: "john@example.com", displayName: "John", createdAt: createdAt, lastActive: createdAt)
        let user2 = User(id: "user123", email: "john@example.com", displayName: "John", createdAt: createdAt, lastActive: createdAt)
        let user3 = User(id: "user456", email: "jane@example.com", displayName: "Jane", createdAt: createdAt, lastActive: createdAt)

        // When
        var userSet: Set<User> = []
        userSet.insert(user1)
        userSet.insert(user2) // Identical user (same properties)
        userSet.insert(user3)

        // Then: Set should contain only unique users (by all properties, not just ID)
        // Note: User uses synthesized Hashable, so identical users are deduped
        XCTAssertEqual(userSet.count, 2, "Set should contain only unique users")
    }

    // MARK: - Preview Helpers Tests

    func testUser_PreviewHelper_ReturnsValidUser() {
        // Given / When
        let user = User.preview

        // Then
        XCTAssertEqual(user.id, "user1")
        XCTAssertEqual(user.email, "john@example.com")
        XCTAssertEqual(user.displayName, "John")
        XCTAssertEqual(user.householdId, "household1")
    }

    func testUser_PreviewListHelper_ReturnsValidList() {
        // Given / When
        let users = User.previewList

        // Then
        XCTAssertEqual(users.count, 3)
        XCTAssertEqual(users[0].displayName, "John")
        XCTAssertEqual(users[1].displayName, "Sarah")
        XCTAssertEqual(users[2].displayName, "Mike")
    }

    func testUser_PreviewListHelper_ContainsUniqueEmails() {
        // Given / When
        let users = User.previewList

        // Then
        let emails = users.map { $0.email }
        XCTAssertTrue(emails.contains("john@example.com"))
        XCTAssertTrue(emails.contains("sarah@example.com"))
        XCTAssertTrue(emails.contains("mike@example.com"))
    }

    // MARK: - Email Validation Tests (Business Logic)

    func testUser_WithValidEmail_AcceptsEmail() {
        // Given / When
        let user = User(email: "valid.email+tag@example.com", displayName: "Test")

        // Then
        XCTAssertEqual(user.email, "valid.email+tag@example.com")
    }

    func testUser_WithEmptyEmail_AllowsEmptyString() {
        // Given / When
        let user = User(email: "", displayName: "Test")

        // Then
        XCTAssertEqual(user.email, "")
    }

    // MARK: - Edge Cases

    func testUser_WithVeryLongDisplayName_HandlesCorrectly() {
        // Given
        let longName = String(repeating: "A", count: 1000)

        // When
        let user = User(email: "test@example.com", displayName: longName)

        // Then
        XCTAssertEqual(user.displayName.count, 1000)
    }

    func testUser_WithSpecialCharactersInDisplayName_HandlesCorrectly() {
        // Given / When
        let user = User(email: "test@example.com", displayName: "José García-Martínez")

        // Then
        XCTAssertEqual(user.displayName, "José García-Martínez")
    }

    func testUser_WithEmojiInDisplayName_HandlesCorrectly() {
        // Given / When
        let user = User(email: "test@example.com", displayName: "John 👨‍💼")

        // Then
        XCTAssertEqual(user.displayName, "John 👨‍💼")
    }

    func testUser_WithVeryLongAvatarUrl_HandlesCorrectly() {
        // Given
        let longUrl = "https://example.com/" + String(repeating: "a", count: 1000) + ".jpg"

        // When
        let user = User(email: "test@example.com", displayName: "Test", avatarUrl: longUrl)

        // Then
        XCTAssertEqual(user.avatarUrl?.count, longUrl.count)
    }

    func testUser_CreatedAtAndLastActive_InitializeToSimilarTimes() {
        // Given / When
        let user = User(email: "test@example.com", displayName: "Test")

        // Then
        let timeDifference = abs(user.createdAt.timeIntervalSince(user.lastActive))
        XCTAssertLessThan(timeDifference, 1.0, "createdAt and lastActive should be very close")
    }
}
