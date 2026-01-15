import Foundation

struct User: Identifiable, Codable, Hashable {
    let id: String
    let email: String
    var displayName: String
    var avatarUrl: String?
    var householdId: String?
    let createdAt: Date
    var lastActive: Date

    init(
        id: String = UUID().uuidString,
        email: String,
        displayName: String,
        avatarUrl: String? = nil,
        householdId: String? = nil,
        createdAt: Date = Date(),
        lastActive: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarUrl = avatarUrl
        self.householdId = householdId
        self.createdAt = createdAt
        self.lastActive = lastActive
    }
}

// MARK: - Preview Helpers
extension User {
    static var preview: User {
        User(
            id: "user1",
            email: "john@example.com",
            displayName: "John",
            householdId: "household1"
        )
    }

    static var previewList: [User] {
        [
            User(id: "1", email: "john@example.com", displayName: "John"),
            User(id: "2", email: "sarah@example.com", displayName: "Sarah"),
            User(id: "3", email: "mike@example.com", displayName: "Mike")
        ]
    }
}
