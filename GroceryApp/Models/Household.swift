import Foundation

struct Household: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    let inviteCode: String
    var activeStoreId: String?
    var sequenceNumber: Int
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        inviteCode: String? = nil,
        activeStoreId: String? = nil,
        sequenceNumber: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode ?? Household.generateInviteCode()
        self.activeStoreId = activeStoreId
        self.sequenceNumber = sequenceNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func generateInviteCode() -> String {
        let characters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0..<6).map { _ in characters.randomElement()! })
    }
}

// MARK: - Preview Helpers
extension Household {
    static var preview: Household {
        Household(
            id: "household1",
            name: "Smith Family",
            inviteCode: "ABC123",
            activeStoreId: "store1"
        )
    }
}
