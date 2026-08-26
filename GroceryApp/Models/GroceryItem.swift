import Foundation

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

struct GroceryItem: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let name: String
    let normalizedName: String
    var quantity: String?
    var notes: String?
    /// When true, `notes` is trip-scoped and gets wiped when the shopping session finishes.
    var notesEphemeral: Bool = false
    /// Item belongs to the current store-less ad-hoc trip rather than the main list.
    var adHoc: Bool = false
    /// Ad-hoc item pulled off the main list rather than typed fresh. If the trip ends
    /// without it being bought, a pulled item returns to the main list; a fresh one is discarded.
    var adHocPulled: Bool = false
    let isCustom: Bool
    let productId: String?
    var status: ItemStatus
    var lockedBy: String?
    var addedBy: String
    var addedAt: Date
    var version: Int
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
        case id, householdId, name, normalizedName, quantity, notes, notesEphemeral
        case adHoc, adHocPulled
        case isCustom, productId, status, lockedBy, addedBy, addedAt
        case version, images
        // isPendingRemoval and isOptimisticUpdate excluded
    }

    init(
        id: String = UUID().uuidString,
        householdId: String = "",
        name: String,
        normalizedName: String? = nil,
        quantity: String? = nil,
        notes: String? = nil,
        notesEphemeral: Bool = false,
        adHoc: Bool = false,
        adHocPulled: Bool = false,
        isCustom: Bool = false,
        productId: String? = nil,
        status: ItemStatus = .active,
        lockedBy: String? = nil,
        addedBy: String = "",
        addedAt: Date = Date(),
        version: Int = 0,
        images: [ItemImage] = []
    ) {
        self.id = id
        self.householdId = householdId
        self.name = name
        self.normalizedName = normalizedName ?? name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.quantity = quantity
        self.notes = notes
        self.notesEphemeral = notesEphemeral
        self.adHoc = adHoc
        self.adHocPulled = adHocPulled
        self.isCustom = isCustom
        self.productId = productId
        self.status = status
        self.lockedBy = lockedBy
        self.addedBy = addedBy
        self.addedAt = addedAt
        self.version = version
        self.images = images
    }

    // Custom decoder to handle the AWSJSON images field (comes as JSON string)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        householdId = try container.decode(String.self, forKey: .householdId)
        name = try container.decode(String.self, forKey: .name)
        normalizedName = try container.decode(String.self, forKey: .normalizedName)
        quantity = try container.decodeIfPresent(String.self, forKey: .quantity)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        notesEphemeral = (try? container.decode(Bool.self, forKey: .notesEphemeral)) ?? false
        adHoc = (try? container.decode(Bool.self, forKey: .adHoc)) ?? false
        adHocPulled = (try? container.decode(Bool.self, forKey: .adHocPulled)) ?? false
        isCustom = try container.decode(Bool.self, forKey: .isCustom)
        productId = try container.decodeIfPresent(String.self, forKey: .productId)
        status = try container.decode(ItemStatus.self, forKey: .status)
        lockedBy = try container.decodeIfPresent(String.self, forKey: .lockedBy)
        addedBy = try container.decode(String.self, forKey: .addedBy)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        version = try container.decode(Int.self, forKey: .version)

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
}
