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

    /// Mirrors the `CommitAction` enum in amplify/data/resource.ts. These raw values
    /// are what `commitStreamHandler` writes; any drift here silently fails to decode.
    enum CommitAction: String, Codable {
        case addItem = "ADD_ITEM"
        case removeItem = "REMOVE_ITEM"
        case moveToCart = "MOVE_TO_CART"
        case restoreToList = "RESTORE_TO_LIST"
        case moveToSuggestions = "MOVE_TO_SUGGESTIONS"
        case lockItem = "LOCK_ITEM"
        case unlockItem = "UNLOCK_ITEM"
        case addReaction = "ADD_REACTION"
        case removeReaction = "REMOVE_REACTION"
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
