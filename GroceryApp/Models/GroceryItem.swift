import Foundation

struct ItemReaction: Codable, Hashable, Equatable {
    let emoji: String
    let userId: String
    let addedAt: Date

    // Custom date decoding to handle ISO8601 strings
    private enum CodingKeys: String, CodingKey {
        case emoji, userId, addedAt
    }

    init(emoji: String, userId: String, addedAt: Date) {
        self.emoji = emoji
        self.userId = userId
        self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emoji = try container.decode(String.self, forKey: .emoji)
        userId = try container.decode(String.self, forKey: .userId)

        // Handle both Date and String formats
        if let date = try? container.decode(Date.self, forKey: .addedAt) {
            addedAt = date
        } else if let dateString = try? container.decode(String.self, forKey: .addedAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                addedAt = date
            } else {
                // Try without fractional seconds
                formatter.formatOptions = [.withInternetDateTime]
                addedAt = formatter.date(from: dateString) ?? Date()
            }
        } else {
            addedAt = Date()
        }
    }
}

struct ItemImage: Codable, Hashable, Identifiable {
    let id: String           // UUID
    let s3Key: String        // S3 storage key
    let uploadedBy: String   // userId
    let uploadedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, s3Key, uploadedBy, uploadedAt
    }

    init(id: String, s3Key: String, uploadedBy: String, uploadedAt: Date) {
        self.id = id
        self.s3Key = s3Key
        self.uploadedBy = uploadedBy
        self.uploadedAt = uploadedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        s3Key = try container.decode(String.self, forKey: .s3Key)
        uploadedBy = try container.decode(String.self, forKey: .uploadedBy)

        // Handle both Date and String formats
        if let date = try? container.decode(Date.self, forKey: .uploadedAt) {
            uploadedAt = date
        } else if let dateString = try? container.decode(String.self, forKey: .uploadedAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                uploadedAt = date
            } else {
                // Try without fractional seconds
                formatter.formatOptions = [.withInternetDateTime]
                uploadedAt = formatter.date(from: dateString) ?? Date()
            }
        } else {
            uploadedAt = Date()
        }
    }
}

enum ReactionEmoji: String, CaseIterable {
    case question = "❓"
    case thumbsUp = "👍"
    case thumbsDown = "👎"
    case heart = "❤️"
    case cart = "🛒"
}

struct GroceryItem: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let name: String
    let normalizedName: String
    var quantity: String?
    var notes: String?
    let isCustom: Bool
    let productId: String?
    var status: ItemStatus
    var lockedBy: String?
    var addedBy: String
    var addedAt: Date
    var version: Int
    var reactions: [ItemReaction] = []
    var images: [ItemImage] = []

    // Transient UI state (not encoded/decoded)
    var isPendingRemoval: Bool = false
    var isOptimisticUpdate: Bool = false
    var isAnimatingIn: Bool = false
    var remoteAddedAt: Date?  // When remotely added during shopping mode
    var hasSeenRemoteBadge: Bool = false  // User has acknowledged the remote badge

    enum ItemStatus: String, Codable {
        case active = "ACTIVE"
        case inCart = "IN_CART"
        case suggestion = "SUGGESTION"
    }

    private enum CodingKeys: String, CodingKey {
        case id, householdId, name, normalizedName, quantity, notes
        case isCustom, productId, status, lockedBy, addedBy, addedAt
        case version, reactions, images
        // isPendingRemoval and isOptimisticUpdate excluded
    }

    init(
        id: String = UUID().uuidString,
        householdId: String = "",
        name: String,
        normalizedName: String? = nil,
        quantity: String? = nil,
        notes: String? = nil,
        isCustom: Bool = false,
        productId: String? = nil,
        status: ItemStatus = .active,
        lockedBy: String? = nil,
        addedBy: String = "",
        addedAt: Date = Date(),
        version: Int = 0,
        reactions: [ItemReaction] = [],
        images: [ItemImage] = []
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.normalizedName = normalizedName ?? name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.quantity = quantity
        self.notes = notes
        self.isCustom = isCustom
        self.productId = productId
        self.status = status
        self.lockedBy = lockedBy
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.version = version
        self.reactions = reactions
        self.images = images
    }

    // Custom decoder to handle AWSJSON reactions field (comes as JSON string)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        householdId = try container.decode(String.self, forKey: .householdId)
        name = try container.decode(String.self, forKey: .name)
        normalizedName = try container.decode(String.self, forKey: .normalizedName)
        quantity = try container.decodeIfPresent(String.self, forKey: .quantity)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        isCustom = try container.decode(Bool.self, forKey: .isCustom)
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
        status = try container.decode(ItemStatus.self, forKey: .status)
        lockedBy = try container.decodeIfPresent(String.self, forKey: .lockedBy)
        addedBy = try container.decode(String.self, forKey: .addedBy)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        version = try container.decode(Int.self, forKey: .version)

        // Handle reactions - can be JSON string (from AWSJSON), array, or nil
        if let reactionsString = try? container.decode(String.self, forKey: .reactions),
           let jsonData = reactionsString.data(using: .utf8) {
            // AWSJSON comes as a JSON string - parse it
            let jsonDecoder = JSONDecoder()
            jsonDecoder.dateDecodingStrategy = .iso8601
            reactions = (try? jsonDecoder.decode([ItemReaction].self, from: jsonData)) ?? []
        } else if let reactionsArray = try? container.decode([ItemReaction].self, forKey: .reactions) {
            // Direct array decoding
            reactions = reactionsArray
        } else {
            reactions = []
        }

        // Handle images - can be JSON string (from AWSJSON), array, or nil
        if let imagesString = try? container.decode(String.self, forKey: .images),
           let jsonData = imagesString.data(using: .utf8) {
            // AWSJSON comes as a JSON string - parse it
            let jsonDecoder = JSONDecoder()
            jsonDecoder.dateDecodingStrategy = .iso8601
            images = (try? jsonDecoder.decode([ItemImage].self, from: jsonData)) ?? []
        } else if let imagesArray = try? container.decode([ItemImage].self, forKey: .images) {
            // Direct array decoding
            images = imagesArray
        } else {
            images = []
        }
    }
}

// MARK: - Preview Helpers
extension GroceryItem {
    static var preview: GroceryItem {
        GroceryItem(
            id: "1",
            householdId: "household1",
            name: "Milk",
            quantity: "1 gallon",
            notes: "Organic",
            addedBy: "user1"
        )
    }

    static var customPreview: GroceryItem {
        GroceryItem(
            id: "2",
            householdId: "household1",
            name: "Trader Joe's Everything Bagel Seasoning",
            isCustom: true,
            addedBy: "user2"
        )
    }

    static var lockedPreview: GroceryItem {
        GroceryItem(
            id: "3",
            householdId: "household1",
            name: "Coffee",
            lockedBy: "user123",
            addedBy: "user1"
        )
    }

    static var animatingInPreview: GroceryItem {
        var item = GroceryItem(
            id: "4",
            householdId: "household1",
            name: "Bananas",
            quantity: "6",
            addedBy: "user2"
        )
        item.isAnimatingIn = true
        return item
    }

    static var withReactionsPreview: GroceryItem {
        GroceryItem(
            id: "5",
            householdId: "household1",
            name: "Pizza",
            quantity: "2",
            addedBy: "user1",
            reactions: [
                ItemReaction(emoji: "❤️", userId: "user1", addedAt: Date()),
                ItemReaction(emoji: "👍", userId: "user2", addedAt: Date()),
                ItemReaction(emoji: "🛒", userId: "user3", addedAt: Date())
            ]
        )
    }
}
