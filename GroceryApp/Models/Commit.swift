import Foundation

struct Commit: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let sequenceNumber: Int
    let author: String
    let authorName: String
    let action: CommitAction
    let payload: String // JSON string
    let timestamp: Date

    enum CommitAction: String, Codable {
        case addItem = "ADD_ITEM"
        case removeItem = "REMOVE_ITEM"
        case checkOffItem = "CHECK_OFF_ITEM"
        case restoreItem = "RESTORE_ITEM"
        case lockItem = "LOCK_ITEM"
        case unlockItem = "UNLOCK_ITEM"
        case updateItem = "UPDATE_ITEM"
    }

    init(
        id: String = UUID().uuidString,
        householdId: String,
        sequenceNumber: Int,
        author: String,
        authorName: String,
        action: CommitAction,
        payload: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.householdId = householdId
        self.sequenceNumber = sequenceNumber
        self.author = author
        self.authorName = authorName
        self.action = action
        self.payload = payload
        self.timestamp = timestamp
    }
}

// MARK: - Preview Helpers
extension Commit {
    static var preview: Commit {
        Commit(
            id: "commit1",
            householdId: "household1",
            sequenceNumber: 42,
            author: "user1",
            authorName: "John",
            action: .addItem,
            payload: #"{"itemId":"item1","name":"Milk"}"#
        )
    }
}
