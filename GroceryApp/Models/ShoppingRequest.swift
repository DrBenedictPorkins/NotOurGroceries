import Foundation

struct ShoppingRequest: Identifiable, Codable, Hashable {
    let id: String
    let householdId: String
    let requestType: RequestType
    let itemName: String
    let normalizedName: String?
    var quantity: String?
    var notes: String?
    let productId: String?
    let targetItemId: String?  // For REMOVE requests
    let requestedBy: String
    let requestedAt: Date
    var status: RequestStatus
    var resolvedBy: String?
    var resolvedAt: Date?

    enum RequestType: String, Codable {
        case addItem = "ADD_ITEM"
        case removeItem = "REMOVE_ITEM"
    }

    enum RequestStatus: String, Codable {
        case pending = "PENDING"
        case approved = "APPROVED"
        case rejected = "REJECTED"
    }

    init(
        id: String = UUID().uuidString,
        householdId: String,
        requestType: RequestType,
        itemName: String,
        normalizedName: String? = nil,
        quantity: String? = nil,
        notes: String? = nil,
        productId: String? = nil,
        targetItemId: String? = nil,
        requestedBy: String,
        requestedAt: Date = Date(),
        status: RequestStatus = .pending,
        resolvedBy: String? = nil,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.householdId = householdId
        self.requestType = requestType
        self.itemName = itemName
        self.normalizedName = normalizedName ?? itemName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        self.quantity = quantity
        self.notes = notes
        self.productId = productId
        self.targetItemId = targetItemId
        self.requestedBy = requestedBy
        self.requestedAt = requestedAt
        self.status = status
        self.resolvedBy = resolvedBy
        self.resolvedAt = resolvedAt
    }
}

// MARK: - Computed Properties
extension ShoppingRequest {
    var isAddRequest: Bool {
        requestType == .addItem
    }

    var isRemoveRequest: Bool {
        requestType == .removeItem
    }

    var isPending: Bool {
        status == .pending
    }

    var isApproved: Bool {
        status == .approved
    }

    var isRejected: Bool {
        status == .rejected
    }

    var isResolved: Bool {
        status == .approved || status == .rejected
    }
}

// MARK: - Preview Helpers
extension ShoppingRequest {
    static var preview: ShoppingRequest {
        ShoppingRequest(
            id: "request1",
            householdId: "household1",
            requestType: .addItem,
            itemName: "Milk",
            quantity: "1 gallon",
            notes: "Organic",
            requestedBy: "user1"
        )
    }

    static var removeRequestPreview: ShoppingRequest {
        ShoppingRequest(
            id: "request2",
            householdId: "household1",
            requestType: .removeItem,
            itemName: "Bananas",
            targetItemId: "item123",
            requestedBy: "user2"
        )
    }

    static var approvedRequestPreview: ShoppingRequest {
        ShoppingRequest(
            id: "request3",
            householdId: "household1",
            requestType: .addItem,
            itemName: "Coffee",
            quantity: "1 lb",
            requestedBy: "user1",
            status: .approved,
            resolvedBy: "user2",
            resolvedAt: Date()
        )
    }

    static var rejectedRequestPreview: ShoppingRequest {
        ShoppingRequest(
            id: "request4",
            householdId: "household1",
            requestType: .removeItem,
            itemName: "Eggs",
            targetItemId: "item456",
            requestedBy: "user2",
            status: .rejected,
            resolvedBy: "user1",
            resolvedAt: Date()
        )
    }
}
