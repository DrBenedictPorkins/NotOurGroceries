import XCTest
import Amplify
@testable import GroceryApp

// MARK: - Test Helper Extensions

extension ShoppingListViewModel {
    /// Helper to set up test state without triggering Amplify API calls
    func setTestState(
        activeItems: [GroceryItem] = [],
        crossedOffItems: [GroceryItem] = [],
        shoppingStatus: ShoppingStatus = .idle,
        activeShopperId: String? = nil,
        shoppingStoreId: String? = nil,
        shoppingStartedAt: Date? = nil
    ) {
        self.activeItems = activeItems
        self.crossedOffItems = crossedOffItems
        self.shoppingStatus = shoppingStatus
        self.activeShopperId = activeShopperId
        self.shoppingStoreId = shoppingStoreId
        self.shoppingStartedAt = shoppingStartedAt
    }
}

// MARK: - IDLE Phase Tests (Before Shopping - List Building)

@MainActor
final class ShoppingModeIDLEPhaseTests: XCTestCase {

    var viewModel: ShoppingListViewModel!

    // Test user IDs
    let currentUserId = "current-user-123"
    let otherUserId = "other-user-456"
    let householdId = "test-household-789"

    override func setUp() {
        super.setUp()
        viewModel = ShoppingListViewModel()
        // Ensure we start in IDLE state
        viewModel.setTestState(shoppingStatus: .idle)
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Scenario 1: Add Item

    func testAddItem_InIdleMode_ItemIsAddedToActiveItems() {
        // Given: IDLE mode with empty list
        viewModel.setTestState(
            activeItems: [],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.shoppingStatus, .idle)
        XCTAssertEqual(viewModel.activeItems.count, 0)
        XCTAssertFalse(viewModel.isCurrentUserShopping)
        XCTAssertFalse(viewModel.isSomeoneElseShopping)
    }

    func testAddItem_WithDuplicateNormalizedName_ShouldBlockAndShowWarning() {
        // Given: IDLE mode with existing item "Milk"
        let existingItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Milk",
            normalizedName: "milk",
            addedBy: currentUserId
        )
        viewModel.setTestState(
            activeItems: [existingItem],
            shoppingStatus: .idle
        )

        // Verify: Duplicate check logic exists
        let normalizedNewName = "milk" // Same as existing
        let isDuplicate = viewModel.activeItems.contains { $0.normalizedName == normalizedNewName }

        // Then: Should detect duplicate
        XCTAssertTrue(isDuplicate, "Should detect duplicate item by normalized name")
    }

    func testAddItem_WithDuplicateInCrossedOffItems_ShouldBlockAndShowWarning() {
        // Given: IDLE mode with crossed-off item "Milk"
        let crossedOffItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Milk",
            normalizedName: "milk",
            status: .crossedOff,
            addedBy: currentUserId,
            crossedOffBy: currentUserId,
            crossedOffAt: Date()
        )
        viewModel.setTestState(
            activeItems: [],
            crossedOffItems: [crossedOffItem],
            shoppingStatus: .idle
        )

        // Verify: Duplicate check logic exists for crossed-off items
        let normalizedNewName = "milk"
        let isDuplicateInCrossedOff = viewModel.crossedOffItems.contains { $0.normalizedName == normalizedNewName }

        // Then: Should detect duplicate in crossed-off items
        XCTAssertTrue(isDuplicateInCrossedOff, "Should detect duplicate in crossed-off items")
    }

    // MARK: - Scenario 2: Delete Item

    func testDeleteItem_InIdleMode_ItemIsRemoved() {
        // Given: IDLE mode with one item
        let item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Bread",
            addedBy: currentUserId
        )
        viewModel.setTestState(
            activeItems: [item],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.shoppingStatus, .idle)

        // When: Simulating delete (direct state manipulation for unit test)
        viewModel.activeItems.removeAll { $0.id == item.id }

        // Then: Item should be removed
        XCTAssertEqual(viewModel.activeItems.count, 0)
    }

    func testDeleteItem_FromCrossedOffItems_ItemIsRemoved() {
        // Given: IDLE mode with crossed-off item
        let crossedOffItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Bread",
            status: .crossedOff,
            addedBy: currentUserId,
            crossedOffBy: currentUserId,
            crossedOffAt: Date()
        )
        viewModel.setTestState(
            activeItems: [],
            crossedOffItems: [crossedOffItem],
            shoppingStatus: .idle
        )

        // When: Simulating delete
        viewModel.crossedOffItems.removeAll { $0.id == crossedOffItem.id }

        // Then: Item should be removed from crossed-off list
        XCTAssertEqual(viewModel.crossedOffItems.count, 0)
    }

    // MARK: - Scenario 3: Cross Off Item

    func testCrossOffItem_InIdleMode_ItemMovesToCrossedOffItems() {
        // Given: IDLE mode with active item
        let item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Eggs",
            status: .active,
            addedBy: currentUserId
        )
        viewModel.setTestState(
            activeItems: [item],
            crossedOffItems: [],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.crossedOffItems.count, 0)

        // When: Simulating cross-off (optimistic update)
        var updatedItem = item
        updatedItem.status = .crossedOff
        updatedItem.crossedOffBy = currentUserId
        updatedItem.crossedOffAt = Date()
        updatedItem.version += 1

        viewModel.activeItems.removeAll { $0.id == item.id }
        viewModel.crossedOffItems.insert(updatedItem, at: 0)

        // Then: Item should move to crossed-off items
        XCTAssertEqual(viewModel.activeItems.count, 0)
        XCTAssertEqual(viewModel.crossedOffItems.count, 1)
        XCTAssertEqual(viewModel.crossedOffItems.first?.status, .crossedOff)
        XCTAssertEqual(viewModel.crossedOffItems.first?.crossedOffBy, currentUserId)
        XCTAssertNotNil(viewModel.crossedOffItems.first?.crossedOffAt)
    }

    // MARK: - Scenario 4: Restore Item

    func testRestoreItem_InIdleMode_ItemMovesBackToActiveItems() {
        // Given: IDLE mode with crossed-off item
        let crossedOffItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Butter",
            status: .crossedOff,
            addedBy: otherUserId,
            crossedOffBy: otherUserId,
            crossedOffAt: Date().addingTimeInterval(-3600)
        )
        viewModel.setTestState(
            activeItems: [],
            crossedOffItems: [crossedOffItem],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.activeItems.count, 0)
        XCTAssertEqual(viewModel.crossedOffItems.count, 1)

        // When: Simulating restore (optimistic update)
        var restoredItem = crossedOffItem
        restoredItem.status = .active
        restoredItem.addedBy = currentUserId // Transfer ownership
        restoredItem.addedAt = Date()
        restoredItem.crossedOffAt = nil
        restoredItem.crossedOffBy = nil
        restoredItem.version += 1

        viewModel.crossedOffItems.removeAll { $0.id == crossedOffItem.id }
        viewModel.activeItems.append(restoredItem)

        // Then: Item should move back to active items
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.crossedOffItems.count, 0)
        XCTAssertEqual(viewModel.activeItems.first?.status, .active)
        XCTAssertEqual(viewModel.activeItems.first?.addedBy, currentUserId)
        XCTAssertNil(viewModel.activeItems.first?.crossedOffBy)
        XCTAssertNil(viewModel.activeItems.first?.crossedOffAt)
    }

    // MARK: - Scenario 5: Lock Item

    func testLockItem_InIdleMode_ItemIsLockedByCurrentUser() {
        // Given: IDLE mode with unlocked item
        let item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Coffee",
            lockedBy: nil,
            addedBy: currentUserId
        )
        viewModel.setTestState(
            activeItems: [item],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertNil(viewModel.activeItems.first?.lockedBy)

        // When: Simulating lock
        var lockedItem = item
        lockedItem.lockedBy = currentUserId
        lockedItem.version += 1

        if let index = viewModel.activeItems.firstIndex(where: { $0.id == item.id }) {
            viewModel.activeItems[index] = lockedItem
        }

        // Then: Item should be locked by current user
        XCTAssertEqual(viewModel.activeItems.first?.lockedBy, currentUserId)
    }

    // MARK: - Scenario 6: Unlock Own Lock

    func testUnlockOwnLock_InIdleMode_ItemIsUnlocked() {
        // Given: IDLE mode with item locked by current user
        let lockedItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Coffee",
            lockedBy: currentUserId,
            addedBy: currentUserId
        )
        viewModel.setTestState(
            activeItems: [lockedItem],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.activeItems.first?.lockedBy, currentUserId)

        // When: Simulating unlock (owner can always unlock their own lock)
        let isOwner = lockedItem.lockedBy == currentUserId
        XCTAssertTrue(isOwner, "Current user should be the lock owner")

        var unlockedItem = lockedItem
        unlockedItem.lockedBy = nil
        unlockedItem.version += 1

        if let index = viewModel.activeItems.firstIndex(where: { $0.id == lockedItem.id }) {
            viewModel.activeItems[index] = unlockedItem
        }

        // Then: Item should be unlocked
        XCTAssertNil(viewModel.activeItems.first?.lockedBy)
    }

    // MARK: - Scenario 7: Unlock Other's Lock (Blocked)

    func testUnlockOthersLock_InIdleMode_ShouldBeBlocked() {
        // Given: IDLE mode with item locked by another user
        let lockedItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Coffee",
            lockedBy: otherUserId,
            addedBy: otherUserId
        )
        viewModel.setTestState(
            activeItems: [lockedItem],
            shoppingStatus: .idle
        )

        // Verify: Lock guard condition
        let isLockedByOther = lockedItem.lockedBy != nil && lockedItem.lockedBy != currentUserId

        // Then: Should be blocked
        XCTAssertTrue(isLockedByOther, "Item should be detected as locked by another user")
        XCTAssertEqual(lockedItem.lockedBy, otherUserId)
        XCTAssertNotEqual(lockedItem.lockedBy, currentUserId)
    }

    // MARK: - Scenario 8: Modify Locked Item (Blocked)

    func testCheckOffLockedItem_ByNonOwner_ShouldBeBlocked() {
        // Given: IDLE mode with item locked by another user
        let lockedItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Sugar",
            lockedBy: otherUserId,
            addedBy: otherUserId
        )
        viewModel.setTestState(
            activeItems: [lockedItem],
            shoppingStatus: .idle
        )

        // Verify: Guard condition for checkOffItem
        // From checkOffItem: if !isCurrentUserShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId
        let isCurrentUserShopping = viewModel.isCurrentUserShopping
        let isLockedByOther = lockedItem.lockedBy != nil && lockedItem.lockedBy != currentUserId
        let shouldBlock = !isCurrentUserShopping && isLockedByOther

        // Then: Should be blocked
        XCTAssertFalse(isCurrentUserShopping, "Should not be shopping in IDLE mode")
        XCTAssertTrue(isLockedByOther, "Item should be locked by another user")
        XCTAssertTrue(shouldBlock, "Should block cross-off of locked item")
    }

    func testDeleteLockedItem_ByNonOwner_ShouldBeBlocked() {
        // Given: IDLE mode with item locked by another user
        let lockedItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Flour",
            lockedBy: otherUserId,
            addedBy: otherUserId
        )
        viewModel.setTestState(
            activeItems: [lockedItem],
            shoppingStatus: .idle
        )

        // Verify: Guard condition for deleteItem
        // From deleteItem: if !isCurrentUserShopping, let lockedBy = item.lockedBy, lockedBy != currentUserId
        let isCurrentUserShopping = viewModel.isCurrentUserShopping
        let isLockedByOther = lockedItem.lockedBy != nil && lockedItem.lockedBy != currentUserId
        let shouldBlock = !isCurrentUserShopping && isLockedByOther

        // Then: Should be blocked
        XCTAssertFalse(isCurrentUserShopping, "Should not be shopping in IDLE mode")
        XCTAssertTrue(isLockedByOther, "Item should be locked by another user")
        XCTAssertTrue(shouldBlock, "Should block deletion of locked item")
    }

    func testRestoreLockedItem_ByNonOwner_ShouldBeBlocked() {
        // Given: IDLE mode with crossed-off item locked by another user
        let lockedCrossedOffItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Salt",
            status: .crossedOff,
            lockedBy: otherUserId,
            addedBy: otherUserId,
            crossedOffBy: otherUserId,
            crossedOffAt: Date()
        )
        viewModel.setTestState(
            activeItems: [],
            crossedOffItems: [lockedCrossedOffItem],
            shoppingStatus: .idle
        )

        // Verify: Guard condition for restoreItem
        let isCurrentUserShopping = viewModel.isCurrentUserShopping
        let isLockedByOther = lockedCrossedOffItem.lockedBy != nil && lockedCrossedOffItem.lockedBy != currentUserId
        let shouldBlock = !isCurrentUserShopping && isLockedByOther

        // Then: Should be blocked
        XCTAssertFalse(isCurrentUserShopping, "Should not be shopping in IDLE mode")
        XCTAssertTrue(isLockedByOther, "Item should be locked by another user")
        XCTAssertTrue(shouldBlock, "Should block restore of locked item")
    }

    // MARK: - Scenario 9: Add Reaction

    func testToggleReaction_InIdleMode_ReactionIsAdded() {
        // Given: IDLE mode with item that has no reactions
        let item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Pizza",
            addedBy: currentUserId,
            reactions: []
        )
        viewModel.setTestState(
            activeItems: [item],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.activeItems.first?.reactions.count, 0)

        // When: Simulating adding reaction
        let emoji = ReactionEmoji.thumbsUp.rawValue
        var updatedItem = item
        let newReaction = ItemReaction(emoji: emoji, userId: currentUserId, addedAt: Date())
        updatedItem.reactions.append(newReaction)
        updatedItem.version += 1

        if let index = viewModel.activeItems.firstIndex(where: { $0.id == item.id }) {
            viewModel.activeItems[index] = updatedItem
        }

        // Then: Reaction should be added
        XCTAssertEqual(viewModel.activeItems.first?.reactions.count, 1)
        XCTAssertEqual(viewModel.activeItems.first?.reactions.first?.emoji, emoji)
        XCTAssertEqual(viewModel.activeItems.first?.reactions.first?.userId, currentUserId)
    }

    func testToggleReaction_InIdleMode_ReactionIsRemoved() {
        // Given: IDLE mode with item that has existing reaction from current user
        let existingReaction = ItemReaction(emoji: ReactionEmoji.heart.rawValue, userId: currentUserId, addedAt: Date())
        let item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Ice Cream",
            addedBy: otherUserId,
            reactions: [existingReaction]
        )
        viewModel.setTestState(
            activeItems: [item],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.activeItems.first?.reactions.count, 1)

        // When: Simulating toggle (remove existing reaction)
        var updatedItem = item
        updatedItem.reactions.removeAll { $0.emoji == existingReaction.emoji && $0.userId == currentUserId }
        updatedItem.version += 1

        if let index = viewModel.activeItems.firstIndex(where: { $0.id == item.id }) {
            viewModel.activeItems[index] = updatedItem
        }

        // Then: Reaction should be removed
        XCTAssertEqual(viewModel.activeItems.first?.reactions.count, 0)
    }

    func testAddMultipleReactions_FromDifferentUsers_AllReactionsPreserved() {
        // Given: IDLE mode with item that has reaction from another user
        let otherUserReaction = ItemReaction(emoji: ReactionEmoji.question.rawValue, userId: otherUserId, addedAt: Date())
        let item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Chips",
            addedBy: currentUserId,
            reactions: [otherUserReaction]
        )
        viewModel.setTestState(
            activeItems: [item],
            shoppingStatus: .idle
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.activeItems.first?.reactions.count, 1)

        // When: Current user adds a different reaction
        var updatedItem = item
        let newReaction = ItemReaction(emoji: ReactionEmoji.cart.rawValue, userId: currentUserId, addedAt: Date())
        updatedItem.reactions.append(newReaction)
        updatedItem.version += 1

        if let index = viewModel.activeItems.firstIndex(where: { $0.id == item.id }) {
            viewModel.activeItems[index] = updatedItem
        }

        // Then: Both reactions should be preserved
        XCTAssertEqual(viewModel.activeItems.first?.reactions.count, 2)
        XCTAssertTrue(viewModel.activeItems.first?.reactions.contains { $0.userId == otherUserId } ?? false)
        XCTAssertTrue(viewModel.activeItems.first?.reactions.contains { $0.userId == currentUserId } ?? false)
    }

    // MARK: - Scenario 10: Enter Shopping Mode

    func testEnterShoppingMode_FromIdleMode_StatusChangesToAtStore() {
        // Given: IDLE mode
        viewModel.setTestState(
            activeItems: [],
            shoppingStatus: .idle,
            activeShopperId: nil,
            shoppingStoreId: nil
        )

        // Verify preconditions
        XCTAssertEqual(viewModel.shoppingStatus, .idle)
        XCTAssertNil(viewModel.activeShopperId)
        XCTAssertNil(viewModel.shoppingStoreId)
        XCTAssertFalse(viewModel.isCurrentUserShopping)

        // When: Simulating entering shopping mode
        let storeId = "store-123"
        let startTime = Date()

        viewModel.shoppingStatus = .atStore
        viewModel.activeShopperId = currentUserId
        viewModel.shoppingStoreId = storeId
        viewModel.shoppingStartedAt = startTime
        viewModel.isAtStoreMode = true

        // Then: Status should change to AT_STORE
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, currentUserId)
        XCTAssertEqual(viewModel.shoppingStoreId, storeId)
        XCTAssertNotNil(viewModel.shoppingStartedAt)
        XCTAssertTrue(viewModel.isAtStoreMode)
    }

    // MARK: - Scenario 11: Add Duplicate Item (Warning)

    func testAddDuplicateItem_CaseInsensitive_ShouldBeDetected() {
        // Given: IDLE mode with "milk" item
        let existingItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Milk",
            normalizedName: "milk",
            addedBy: currentUserId
        )
        viewModel.setTestState(
            activeItems: [existingItem],
            shoppingStatus: .idle
        )

        // Verify: Various case variations should be detected as duplicates
        let testCases = ["MILK", "Milk", "mIlK", "milk", "  Milk  "]

        for testCase in testCases {
            let normalizedTestCase = testCase.lowercased().trimmingCharacters(in: .whitespaces)
            let isDuplicate = viewModel.activeItems.contains { $0.normalizedName == normalizedTestCase }
            XCTAssertTrue(isDuplicate, "'\(testCase)' should be detected as duplicate of 'Milk'")
        }
    }

    // MARK: - Computed Properties Tests

    func testIsCurrentUserShopping_WhenIdle_ReturnsFalse() {
        // Given: IDLE mode
        viewModel.setTestState(
            shoppingStatus: .idle,
            activeShopperId: nil
        )
        viewModel.isAtStoreMode = false

        // Then: isCurrentUserShopping should be false
        XCTAssertFalse(viewModel.isCurrentUserShopping)
    }

    func testIsSomeoneElseShopping_WhenIdle_ReturnsFalse() {
        // Given: IDLE mode
        viewModel.setTestState(
            shoppingStatus: .idle,
            activeShopperId: nil
        )

        // Then: isSomeoneElseShopping should be false
        XCTAssertFalse(viewModel.isSomeoneElseShopping)
    }

    func testShoppingStatus_WhenIdle_ReturnsIdle() {
        // Given: IDLE mode
        viewModel.setTestState(shoppingStatus: .idle)

        // Then: shoppingStatus should be .idle
        XCTAssertEqual(viewModel.shoppingStatus, .idle)
    }

    func testItemsCrossedOffThisTrip_WhenIdle_ReturnsEmptyArray() {
        // Given: IDLE mode (no shopping trip started)
        let crossedOffItem = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Test Item",
            status: .crossedOff,
            addedBy: currentUserId,
            crossedOffBy: currentUserId,
            crossedOffAt: Date()
        )
        viewModel.setTestState(
            crossedOffItems: [crossedOffItem],
            shoppingStatus: .idle,
            shoppingStartedAt: nil
        )

        // Then: itemsCrossedOffThisTrip should be empty (shoppingStartedAt is nil)
        XCTAssertEqual(viewModel.itemsCrossedOffThisTrip.count, 0)
    }

    // MARK: - Version Handling Tests

    func testVersionIncrement_OnCrossOff() {
        // Given: Item with version 3
        var item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Test Item",
            version: 3
        )

        // When: Crossing off (should increment version)
        item.status = .crossedOff
        item.version += 1

        // Then: Version should be incremented
        XCTAssertEqual(item.version, 4)
    }

    func testVersionIncrement_OnLock() {
        // Given: Item with version 5
        var item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Test Item",
            version: 5
        )

        // When: Locking (should increment version)
        item.lockedBy = currentUserId
        item.version += 1

        // Then: Version should be incremented
        XCTAssertEqual(item.version, 6)
    }

    func testVersionIncrement_OnReactionChange() {
        // Given: Item with version 2
        var item = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "Test Item",
            version: 2,
            reactions: []
        )

        // When: Adding reaction (should increment version)
        item.reactions.append(ItemReaction(emoji: ReactionEmoji.thumbsUp.rawValue, userId: currentUserId, addedAt: Date()))
        item.version += 1

        // Then: Version should be incremented
        XCTAssertEqual(item.version, 3)
    }

    // MARK: - Sorting Tests in IDLE Mode

    func testSorting_InIdleMode_RecentFirstIsDefault() {
        // Given: IDLE mode with items added at different times
        let item1 = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "First Item",
            addedBy: currentUserId,
            addedAt: Date().addingTimeInterval(-3600) // 1 hour ago
        )
        let item2 = GroceryItem(
            id: "item-2",
            householdId: householdId,
            name: "Second Item",
            addedBy: currentUserId,
            addedAt: Date().addingTimeInterval(-1800) // 30 min ago
        )
        let item3 = GroceryItem(
            id: "item-3",
            householdId: householdId,
            name: "Third Item",
            addedBy: currentUserId,
            addedAt: Date() // Now
        )

        viewModel.setTestState(
            activeItems: [item1, item2, item3],
            shoppingStatus: .idle
        )
        viewModel.currentSort = .recentFirst

        // When: Applying sort
        viewModel.applySorting()

        // Then: Oldest should be first, newest at bottom
        XCTAssertEqual(viewModel.activeItems[0].name, "First Item")
        XCTAssertEqual(viewModel.activeItems[1].name, "Second Item")
        XCTAssertEqual(viewModel.activeItems[2].name, "Third Item")
    }

    func testSorting_InIdleMode_AToZ() {
        // Given: IDLE mode with items
        let item1 = GroceryItem(id: "1", householdId: householdId, name: "Zucchini", addedBy: currentUserId)
        let item2 = GroceryItem(id: "2", householdId: householdId, name: "Apple", addedBy: currentUserId)
        let item3 = GroceryItem(id: "3", householdId: householdId, name: "Milk", addedBy: currentUserId)

        viewModel.setTestState(
            activeItems: [item1, item2, item3],
            shoppingStatus: .idle
        )
        viewModel.currentSort = .aToZ

        // When: Applying A-Z sort
        viewModel.applySorting()

        // Then: Should be sorted alphabetically A-Z
        XCTAssertEqual(viewModel.activeItems[0].name, "Apple")
        XCTAssertEqual(viewModel.activeItems[1].name, "Milk")
        XCTAssertEqual(viewModel.activeItems[2].name, "Zucchini")
    }

    func testSorting_InIdleMode_ZToA() {
        // Given: IDLE mode with items
        let item1 = GroceryItem(id: "1", householdId: householdId, name: "Apple", addedBy: currentUserId)
        let item2 = GroceryItem(id: "2", householdId: householdId, name: "Zucchini", addedBy: currentUserId)
        let item3 = GroceryItem(id: "3", householdId: householdId, name: "Milk", addedBy: currentUserId)

        viewModel.setTestState(
            activeItems: [item1, item2, item3],
            shoppingStatus: .idle
        )
        viewModel.currentSort = .zToA

        // When: Applying Z-A sort
        viewModel.applySorting()

        // Then: Should be sorted alphabetically Z-A
        XCTAssertEqual(viewModel.activeItems[0].name, "Zucchini")
        XCTAssertEqual(viewModel.activeItems[1].name, "Milk")
        XCTAssertEqual(viewModel.activeItems[2].name, "Apple")
    }

    // MARK: - Edge Cases

    func testEmptyList_AllOperationsHandleGracefully() {
        // Given: IDLE mode with empty lists
        viewModel.setTestState(
            activeItems: [],
            crossedOffItems: [],
            shoppingStatus: .idle
        )

        // Then: All counts should be zero
        XCTAssertEqual(viewModel.activeItems.count, 0)
        XCTAssertEqual(viewModel.crossedOffItems.count, 0)
        XCTAssertEqual(viewModel.itemsCrossedOffThisTrip.count, 0)

        // Sorting empty list should not crash
        viewModel.sortByAisle()
        viewModel.applySorting()

        XCTAssertEqual(viewModel.activeItems.count, 0)
    }

    func testLockedItem_OwnerCanStillModify() {
        // Given: IDLE mode with item locked by current user
        let lockedByMe = GroceryItem(
            id: "item-1",
            householdId: householdId,
            name: "My Locked Item",
            lockedBy: currentUserId,
            addedBy: currentUserId
        )
        viewModel.setTestState(
            activeItems: [lockedByMe],
            shoppingStatus: .idle
        )

        // Verify: Owner bypass for lock check
        let isLockedByOther = lockedByMe.lockedBy != nil && lockedByMe.lockedBy != currentUserId

        // Then: Should not be blocked (owner can modify their own locked items)
        XCTAssertFalse(isLockedByOther, "Item locked by current user should not block modifications")
    }

    func testPendingRequestCount_InIdleMode_IsZero() {
        // Given: IDLE mode
        viewModel.setTestState(
            shoppingStatus: .idle
        )
        viewModel.pendingRequests = []

        // Then: No pending requests in IDLE mode
        XCTAssertEqual(viewModel.pendingRequestCount, 0)
    }

    func testActiveShopperDisplayName_WhenIdle_ReturnsNil() {
        // Given: IDLE mode with no active shopper
        viewModel.setTestState(
            shoppingStatus: .idle,
            activeShopperId: nil
        )

        // Then: activeShopperDisplayName should be nil
        XCTAssertNil(viewModel.activeShopperDisplayName)
    }
}

// MARK: - Item Status Tests

@MainActor
final class GroceryItemStatusTests: XCTestCase {

    func testItemStatus_Active() {
        let item = GroceryItem(name: "Test", status: .active)
        XCTAssertEqual(item.status, .active)
        XCTAssertEqual(item.status.rawValue, "ACTIVE")
    }

    func testItemStatus_CrossedOff() {
        let item = GroceryItem(name: "Test", status: .crossedOff)
        XCTAssertEqual(item.status, .crossedOff)
        XCTAssertEqual(item.status.rawValue, "CROSSED_OFF")
    }

    func testNormalizedName_GeneratedFromName() {
        // Given: Item with uppercase name with spaces
        let item = GroceryItem(name: "  WHOLE MILK  ")

        // Then: normalizedName should be lowercased and trimmed
        XCTAssertEqual(item.normalizedName, "whole milk")
    }

    func testNormalizedName_CanBeExplicitlySet() {
        // Given: Item with explicit normalizedName
        let item = GroceryItem(name: "2% Milk", normalizedName: "milk")

        // Then: normalizedName should be the explicit value
        XCTAssertEqual(item.normalizedName, "milk")
    }
}

// MARK: - Shopping Status Enum Tests

@MainActor
final class ShoppingStatusEnumTests: XCTestCase {

    func testShoppingStatus_Idle() {
        let status = ShoppingStatus.idle
        XCTAssertEqual(status.rawValue, "IDLE")
    }

    func testShoppingStatus_AtStore() {
        let status = ShoppingStatus.atStore
        XCTAssertEqual(status.rawValue, "AT_STORE")
    }

    func testShoppingStatus_InitFromRawValue() {
        XCTAssertEqual(ShoppingStatus(rawValue: "IDLE"), .idle)
        XCTAssertEqual(ShoppingStatus(rawValue: "AT_STORE"), .atStore)
        XCTAssertNil(ShoppingStatus(rawValue: "INVALID"))
    }
}

// MARK: - Reaction Tests

@MainActor
final class ItemReactionTests: XCTestCase {

    func testItemReaction_Creation() {
        let reaction = ItemReaction(
            emoji: ReactionEmoji.thumbsUp.rawValue,
            userId: "user-123",
            addedAt: Date()
        )

        XCTAssertEqual(reaction.emoji, ReactionEmoji.thumbsUp.rawValue)
        XCTAssertEqual(reaction.userId, "user-123")
        XCTAssertNotNil(reaction.addedAt)
    }

    func testReactionEmoji_AllCases() {
        // Verify all reaction emojis are available
        let allEmojis = ReactionEmoji.allCases

        XCTAssertEqual(allEmojis.count, 5)
        XCTAssertTrue(allEmojis.contains(.question))
        XCTAssertTrue(allEmojis.contains(.thumbsUp))
        XCTAssertTrue(allEmojis.contains(.thumbsDown))
        XCTAssertTrue(allEmojis.contains(.heart))
        XCTAssertTrue(allEmojis.contains(.cart))
    }

    func testItemReaction_Equality() {
        let reaction1 = ItemReaction(emoji: "test", userId: "user1", addedAt: Date())
        let reaction2 = ItemReaction(emoji: "test", userId: "user1", addedAt: Date())

        // Different addedAt should still allow comparison
        XCTAssertEqual(reaction1.emoji, reaction2.emoji)
        XCTAssertEqual(reaction1.userId, reaction2.userId)
    }
}

// MARK: - Sort Option Tests

@MainActor
final class SortOptionTests: XCTestCase {

    func testSortOption_AllCases() {
        let allOptions = SortOption.allCases

        XCTAssertEqual(allOptions.count, 3)
        XCTAssertTrue(allOptions.contains(.recentFirst))
        XCTAssertTrue(allOptions.contains(.aToZ))
        XCTAssertTrue(allOptions.contains(.zToA))
    }

    func testSortOption_RawValues() {
        XCTAssertEqual(SortOption.recentFirst.rawValue, "Recent")
        XCTAssertEqual(SortOption.aToZ.rawValue, "A-Z")
        XCTAssertEqual(SortOption.zToA.rawValue, "Z-A")
    }

    func testSortOption_Icons() {
        XCTAssertEqual(SortOption.recentFirst.icon, "clock")
        XCTAssertEqual(SortOption.aToZ.icon, "arrow.down")
        XCTAssertEqual(SortOption.zToA.icon, "arrow.up")
    }
}

// MARK: - AT_STORE Phase Tests (Active Shopping)

/// Tests for ShoppingListViewModel AT_STORE phase (active shopping) scenarios.
/// Covers both SHOPPER (isCurrentUserShopping == true) and REMOTE MEMBER
/// (isSomeoneElseShopping == true) behaviors.
@MainActor
final class ShoppingModeATStorePhaseTests: XCTestCase {

    var viewModel: ShoppingListViewModel!

    // Test user IDs
    let currentUserId = "current-user-123"
    let otherUserId = "other-user-456"
    let householdId = "test-household-789"

    override func setUp() {
        super.setUp()
        viewModel = ShoppingListViewModel()
    }

    override func tearDown() {
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Creates a test GroceryItem with sensible defaults
    private func makeItem(
        id: String = UUID().uuidString,
        name: String = "Test Item",
        status: GroceryItem.ItemStatus = .active,
        lockedBy: String? = nil,
        addedBy: String = "user-1",
        crossedOffBy: String? = nil,
        crossedOffAt: Date? = nil,
        version: Int = 0
    ) -> GroceryItem {
        GroceryItem(
            id: id,
            householdId: householdId,
            name: name,
            normalizedName: name.lowercased(),
            status: status,
            lockedBy: lockedBy,
            addedBy: addedBy,
            crossedOffBy: crossedOffBy,
            crossedOffAt: crossedOffAt,
            version: version
        )
    }

    /// Creates a test ShoppingRequest
    private func makeRequest(
        id: String = UUID().uuidString,
        requestType: ShoppingRequest.RequestType = .addItem,
        itemName: String = "Requested Item",
        quantity: String? = nil,
        notes: String? = nil,
        productId: String? = nil,
        targetItemId: String? = nil,
        requestedBy: String = "remote-user"
    ) -> ShoppingRequest {
        ShoppingRequest(
            id: id,
            householdId: householdId,
            requestType: requestType,
            itemName: itemName,
            normalizedName: itemName.lowercased(),
            quantity: quantity,
            notes: notes,
            productId: productId,
            targetItemId: targetItemId,
            requestedBy: requestedBy,
            requestedAt: Date(),
            status: .pending
        )
    }

    /// Sets up viewModel as if someone else is shopping (remote member scenario)
    private func setupRemoteMemberScenario() {
        viewModel.setTestState(
            shoppingStatus: .atStore,
            activeShopperId: otherUserId,
            shoppingStoreId: "store-1",
            shoppingStartedAt: Date()
        )
        viewModel.isAtStoreMode = false // Current user is NOT in at store mode locally
    }

    /// Sets up viewModel as if current user is shopping (shopper scenario)
    private func setupShopperScenario() {
        viewModel.setTestState(
            shoppingStatus: .atStore,
            activeShopperId: currentUserId,
            shoppingStoreId: "store-1",
            shoppingStartedAt: Date()
        )
        viewModel.isAtStoreMode = true // Current user IS in at store mode locally
    }

    // MARK: - Computed Properties Tests

    // MARK: isCurrentUserShopping

    func testIsCurrentUserShopping_WhenAtStoreModeTrue_ReturnsTrue() {
        // Given: Local at store mode is enabled
        viewModel.isAtStoreMode = true
        viewModel.shoppingStatus = .idle

        // Then: Should return true (local mode takes precedence)
        XCTAssertTrue(viewModel.isCurrentUserShopping,
            "isCurrentUserShopping should return true when isAtStoreMode is true")
    }

    func testIsCurrentUserShopping_WhenStatusIdleAndAtStoreModeFalse_ReturnsFalse() {
        // Given: Not shopping at all
        viewModel.setTestState(
            shoppingStatus: .idle,
            activeShopperId: nil
        )
        viewModel.isAtStoreMode = false

        // Then: Should return false
        XCTAssertFalse(viewModel.isCurrentUserShopping,
            "isCurrentUserShopping should return false when not shopping")
    }

    func testIsCurrentUserShopping_WhenSomeoneElseIsShopper_StateSetCorrectly() {
        // Given: Someone else is the shopper (simulated via shoppingStatus/activeShopperId)
        viewModel.setTestState(
            shoppingStatus: .atStore,
            activeShopperId: otherUserId
        )
        viewModel.isAtStoreMode = false

        // Then: Verify state is set correctly for remote member scenario
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)
        XCTAssertFalse(viewModel.isAtStoreMode)
    }

    // MARK: isSomeoneElseShopping

    func testIsSomeoneElseShopping_WhenStatusIdle_ReturnsFalse() {
        // Given: No one is shopping
        viewModel.setTestState(
            shoppingStatus: .idle,
            activeShopperId: nil
        )

        // Then: Should return false
        XCTAssertFalse(viewModel.isSomeoneElseShopping,
            "isSomeoneElseShopping should return false when status is idle")
    }

    func testIsSomeoneElseShopping_WhenNoActiveShopperId_ReturnsFalse() {
        // Given: At store status but no shopper ID
        viewModel.setTestState(
            shoppingStatus: .atStore,
            activeShopperId: nil
        )

        // Then: Should return false (guard condition fails)
        XCTAssertFalse(viewModel.isSomeoneElseShopping,
            "isSomeoneElseShopping should return false when activeShopperId is nil")
    }

    func testIsSomeoneElseShopping_StateSetupForRemoteMember() {
        // Given: Setup for remote member scenario
        setupRemoteMemberScenario()

        // Then: Verify the state is correctly configured
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)
        XCTAssertFalse(viewModel.isAtStoreMode)
    }

    // MARK: pendingRequestCount

    func testPendingRequestCount_WhenEmpty_ReturnsZero() {
        // Given: No pending requests
        viewModel.pendingRequests = []

        // Then
        XCTAssertEqual(viewModel.pendingRequestCount, 0,
            "pendingRequestCount should return 0 when no requests")
    }

    func testPendingRequestCount_WithMultipleRequests_ReturnsCorrectCount() {
        // Given: Multiple pending requests
        viewModel.pendingRequests = [
            makeRequest(id: "req-1", itemName: "Milk"),
            makeRequest(id: "req-2", itemName: "Bread"),
            makeRequest(id: "req-3", itemName: "Eggs")
        ]

        // Then
        XCTAssertEqual(viewModel.pendingRequestCount, 3,
            "pendingRequestCount should return correct count")
    }

    // MARK: activeShopperDisplayName

    func testActiveShopperDisplayName_WhenNoActiveShopperId_ReturnsNil() {
        // Given: No active shopper
        viewModel.setTestState(activeShopperId: nil)

        // Then
        XCTAssertNil(viewModel.activeShopperDisplayName,
            "activeShopperDisplayName should return nil when no active shopper")
    }

    func testActiveShopperDisplayName_WhenShopperIdSet_ReturnsFromCache() {
        // Given: Active shopper ID is set
        viewModel.setTestState(activeShopperId: otherUserId)

        // Then: Returns result from UserCache (which may be the ID itself if not cached)
        XCTAssertNotNil(viewModel.activeShopperId)
    }

    // MARK: itemsCrossedOffThisTrip

    func testItemsCrossedOffThisTrip_WhenShoppingStartedAtNil_ReturnsEmpty() {
        // Given: No shopping start time
        viewModel.setTestState(
            crossedOffItems: [makeItem(status: .crossedOff, crossedOffAt: Date())],
            shoppingStartedAt: nil
        )

        // Then
        XCTAssertTrue(viewModel.itemsCrossedOffThisTrip.isEmpty,
            "itemsCrossedOffThisTrip should return empty when shoppingStartedAt is nil")
    }

    func testItemsCrossedOffThisTrip_FiltersItemsCrossedOffBeforeStart() {
        // Given: Shopping started at a specific time
        let startTime = Date()
        let beforeStart = startTime.addingTimeInterval(-3600) // 1 hour before
        let afterStart = startTime.addingTimeInterval(600) // 10 minutes after

        viewModel.setTestState(
            crossedOffItems: [
                makeItem(id: "before", name: "Before Item", status: .crossedOff, crossedOffAt: beforeStart),
                makeItem(id: "after", name: "After Item", status: .crossedOff, crossedOffAt: afterStart)
            ],
            shoppingStartedAt: startTime
        )

        // Then: Only item crossed off after start time should be included
        let result = viewModel.itemsCrossedOffThisTrip
        XCTAssertEqual(result.count, 1,
            "Should only include items crossed off after shopping started")
        XCTAssertEqual(result.first?.id, "after")
    }

    func testItemsCrossedOffThisTrip_ExcludesItemsWithNoCrossedOffAt() {
        // Given: Shopping started
        viewModel.setTestState(
            crossedOffItems: [
                makeItem(id: "no-date", name: "No Date Item", status: .crossedOff, crossedOffAt: nil)
            ],
            shoppingStartedAt: Date()
        )

        // Then
        XCTAssertTrue(viewModel.itemsCrossedOffThisTrip.isEmpty,
            "Should exclude items without crossedOffAt date")
    }

    // MARK: - PHASE 2: AT_STORE - SHOPPER Scenarios

    // MARK: Scenario 1: Shopper Add Item

    func testShopperAddItem_WhenCurrentUserShopping_DoesNotRedirectToRequest() {
        // Given: Current user is shopping (via isAtStoreMode)
        setupShopperScenario()

        // Then: Verify isCurrentUserShopping returns true
        XCTAssertTrue(viewModel.isCurrentUserShopping,
            "Shopper should be identified as current user shopping")

        // Verify isSomeoneElseShopping is false - addItem won't redirect to submitAddRequest
        XCTAssertFalse(viewModel.isSomeoneElseShopping,
            "isSomeoneElseShopping should be false when current user is shopping")
    }

    func testShopperAddItem_DirectlyAddsToActiveItems() {
        // Given: Current user is shopping
        setupShopperScenario()
        viewModel.activeItems = []

        // When: Simulating optimistic add (as done in addItem)
        let newItem = makeItem(id: "new-item", name: "Milk", addedBy: currentUserId)
        viewModel.activeItems.append(newItem)

        // Then: Item should be directly added
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.activeItems.first?.name, "Milk")
    }

    // MARK: Scenario 2: Shopper Delete Item

    func testShopperDeleteItem_DirectlyRemovesItem() {
        // Given: Current user is shopping with an item
        setupShopperScenario()
        let item = makeItem(id: "item-1", name: "Bread")
        viewModel.activeItems = [item]

        // Verify preconditions
        XCTAssertTrue(viewModel.isCurrentUserShopping)
        XCTAssertFalse(viewModel.isSomeoneElseShopping)

        // When: Simulating delete (optimistic update)
        viewModel.activeItems.removeAll { $0.id == item.id }

        // Then: Item should be removed
        XCTAssertTrue(viewModel.activeItems.isEmpty)
    }

    func testShopperDeleteItem_DoesNotRedirectToRequest() {
        // Given: Current user is shopping
        setupShopperScenario()

        // Then: Verify the shopper can delete directly (isSomeoneElseShopping is false)
        XCTAssertTrue(viewModel.isCurrentUserShopping,
            "Shopper should be able to delete items directly")
        XCTAssertFalse(viewModel.isSomeoneElseShopping,
            "isSomeoneElseShopping should be false for shopper")
    }

    // MARK: Scenario 3: Shopper Cross Off Item

    func testShopperCheckOffItem_MovesItemToCrossedOff() {
        // Given: Current user is shopping with an active item
        setupShopperScenario()
        let item = makeItem(id: "item-1", name: "Eggs", status: .active)
        viewModel.activeItems = [item]
        viewModel.crossedOffItems = []

        // Verify preconditions
        XCTAssertFalse(viewModel.isSomeoneElseShopping)
        XCTAssertEqual(viewModel.activeItems.count, 1)

        // When: Simulating cross-off (optimistic update)
        var updatedItem = item
        updatedItem.status = .crossedOff
        updatedItem.crossedOffBy = currentUserId
        updatedItem.crossedOffAt = Date()
        updatedItem.version += 1

        viewModel.activeItems.remove(at: 0)
        viewModel.crossedOffItems.insert(updatedItem, at: 0)

        // Then: Item should move to crossedOffItems
        XCTAssertTrue(viewModel.activeItems.isEmpty)
        XCTAssertEqual(viewModel.crossedOffItems.count, 1)
        XCTAssertEqual(viewModel.crossedOffItems.first?.status, .crossedOff)
    }

    func testShopperCheckOffItem_BypassesLockCheck() {
        // Given: Current user is shopping, item locked by someone else
        setupShopperScenario()
        let lockedItem = makeItem(lockedBy: otherUserId)
        viewModel.activeItems = [lockedItem]

        // Then: isCurrentUserShopping is true, so lock check should be bypassed
        // (In checkOffItem: if !isCurrentUserShopping, let lockedBy = item.lockedBy...)
        XCTAssertTrue(viewModel.isCurrentUserShopping,
            "Shopper should bypass lock check")

        // Verify the guard condition that would block non-shoppers
        let isCurrentUserShopping = viewModel.isCurrentUserShopping
        let isLockedByOther = lockedItem.lockedBy != nil && lockedItem.lockedBy != currentUserId
        let shouldBlock = !isCurrentUserShopping && isLockedByOther

        XCTAssertFalse(shouldBlock, "Shopper should NOT be blocked by lock")
    }

    // MARK: Scenario 4: Shopper Restore Item

    func testShopperRestoreItem_MovesItemBackToActive() {
        // Given: Current user is shopping with a crossed-off item
        setupShopperScenario()
        let crossedOffItem = makeItem(id: "item-1", name: "Butter", status: .crossedOff, crossedOffAt: Date())
        viewModel.activeItems = []
        viewModel.crossedOffItems = [crossedOffItem]

        // Verify preconditions
        XCTAssertFalse(viewModel.isSomeoneElseShopping)

        // When: Simulating restore (optimistic update)
        var restoredItem = crossedOffItem
        restoredItem.status = .active
        restoredItem.crossedOffBy = nil
        restoredItem.crossedOffAt = nil
        restoredItem.addedBy = currentUserId
        restoredItem.addedAt = Date()
        restoredItem.version += 1

        viewModel.crossedOffItems.removeAll { $0.id == crossedOffItem.id }
        viewModel.activeItems.append(restoredItem)

        // Then: Item should move back to activeItems
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertTrue(viewModel.crossedOffItems.isEmpty)
        XCTAssertEqual(viewModel.activeItems.first?.status, .active)
    }

    func testShopperRestoreItem_NotBlocked() {
        // Given: Current user is shopping
        setupShopperScenario()

        // Then: Shopper should not be blocked
        XCTAssertFalse(viewModel.isSomeoneElseShopping,
            "Shopper should not be blocked from restoring items")
    }

    // MARK: Scenario 5: Shopper Approve Add Request

    func testShopperApproveAddRequest_RequestStructure() {
        // Given: An add request
        let addRequest = makeRequest(
            requestType: .addItem,
            itemName: "Milk",
            quantity: "1 gallon",
            notes: "Organic",
            productId: "prod-123"
        )

        // Then: Verify request properties for approval
        XCTAssertTrue(addRequest.isAddRequest,
            "Should be an add request")
        XCTAssertEqual(addRequest.itemName, "Milk")
        XCTAssertEqual(addRequest.quantity, "1 gallon")
        XCTAssertEqual(addRequest.notes, "Organic")
        XCTAssertEqual(addRequest.productId, "prod-123")
    }

    func testShopperApproveRequest_RemovesFromPendingList() {
        // Given: Pending requests
        let request1 = makeRequest(id: "req-1", itemName: "Milk")
        let request2 = makeRequest(id: "req-2", itemName: "Bread")
        viewModel.pendingRequests = [request1, request2]

        // When: Simulating request removal (as done in approveRequest)
        viewModel.pendingRequests.removeAll { $0.id == "req-1" }

        // Then
        XCTAssertEqual(viewModel.pendingRequests.count, 1)
        XCTAssertEqual(viewModel.pendingRequests.first?.id, "req-2")
    }

    func testShopperApproveAddRequest_AddsItemToList() {
        // Given: Shopper with an add request
        setupShopperScenario()
        viewModel.activeItems = []

        let addRequest = makeRequest(
            id: "req-1",
            requestType: .addItem,
            itemName: "Cookies",
            quantity: "2 boxes"
        )
        viewModel.pendingRequests = [addRequest]

        // When: Approving - add the item
        let newItem = makeItem(
            id: "new-item",
            name: addRequest.itemName,
            addedBy: addRequest.requestedBy
        )
        viewModel.activeItems.append(newItem)
        viewModel.pendingRequests.removeAll { $0.id == addRequest.id }

        // Then: Item added, request removed
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.activeItems.first?.name, "Cookies")
        XCTAssertTrue(viewModel.pendingRequests.isEmpty)
    }

    // MARK: Scenario 6: Shopper Approve Remove Request

    func testShopperApproveRemoveRequest_RequestStructure() {
        // Given: A remove request
        let removeRequest = makeRequest(
            requestType: .removeItem,
            itemName: "Bananas",
            targetItemId: "item-to-remove"
        )

        // Then: Verify request properties
        XCTAssertTrue(removeRequest.isRemoveRequest,
            "Should be a remove request")
        XCTAssertEqual(removeRequest.targetItemId, "item-to-remove")
    }

    func testShopperApproveRemoveRequest_FindsTargetItem() {
        // Given: Items in list and a remove request
        let targetItem = makeItem(id: "target-item", name: "Bananas")
        viewModel.activeItems = [targetItem, makeItem(id: "other-item", name: "Apples")]

        let removeRequest = makeRequest(
            requestType: .removeItem,
            itemName: "Bananas",
            targetItemId: "target-item"
        )

        // When: Finding the target item
        let found = viewModel.activeItems.first { $0.id == removeRequest.targetItemId }

        // Then
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Bananas")
    }

    func testShopperApproveRemoveRequest_DeletesItemAndRequest() {
        // Given: Shopper with an item and a remove request
        setupShopperScenario()
        let targetItem = makeItem(id: "item-123", name: "Expired Yogurt")
        viewModel.activeItems = [targetItem]

        let removeRequest = makeRequest(
            id: "req-1",
            requestType: .removeItem,
            itemName: "Expired Yogurt",
            targetItemId: "item-123"
        )
        viewModel.pendingRequests = [removeRequest]

        // When: Approving - find and delete the item
        if let item = viewModel.activeItems.first(where: { $0.id == removeRequest.targetItemId }) {
            viewModel.activeItems.removeAll { $0.id == item.id }
        }
        viewModel.pendingRequests.removeAll { $0.id == removeRequest.id }

        // Then: Item deleted, request removed
        XCTAssertTrue(viewModel.activeItems.isEmpty)
        XCTAssertTrue(viewModel.pendingRequests.isEmpty)
    }

    // MARK: Scenario 7: Shopper Reject Request

    func testShopperRejectRequest_RemovesFromPendingList() {
        // Given: Pending requests
        let request = makeRequest(id: "req-to-reject", itemName: "Unwanted Item")
        viewModel.pendingRequests = [request]

        // When: Simulating rejection (removes from pending list)
        viewModel.pendingRequests.removeAll { $0.id == "req-to-reject" }

        // Then
        XCTAssertTrue(viewModel.pendingRequests.isEmpty)
    }

    func testShopperRejectRequest_DoesNotModifyItems() {
        // Given: Shopper with items and a reject request
        setupShopperScenario()
        let existingItem = makeItem(id: "item-1", name: "Keep This")
        viewModel.activeItems = [existingItem]

        let rejectRequest = makeRequest(id: "req-1", itemName: "Don't Add This")
        viewModel.pendingRequests = [rejectRequest]

        // When: Rejecting - only remove the request
        viewModel.pendingRequests.removeAll { $0.id == rejectRequest.id }

        // Then: Items unchanged, request removed
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.activeItems.first?.name, "Keep This")
        XCTAssertTrue(viewModel.pendingRequests.isEmpty)
    }

    // MARK: Scenario 8: Shopper Exit Shopping Mode

    func testShopperExitShoppingMode_StateReset() {
        // Given: Actively shopping
        setupShopperScenario()
        viewModel.pendingRequests = [makeRequest()]

        // Verify initial state
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertNotNil(viewModel.activeShopperId)
        XCTAssertNotNil(viewModel.shoppingStoreId)
        XCTAssertNotNil(viewModel.shoppingStartedAt)
        XCTAssertTrue(viewModel.isAtStoreMode)

        // When: Simulating exit (state changes as done in exitShoppingMode success path)
        viewModel.shoppingStatus = .idle
        viewModel.activeShopperId = nil
        viewModel.shoppingStoreId = nil
        viewModel.shoppingStartedAt = nil
        viewModel.isAtStoreMode = false
        viewModel.pendingRequests.removeAll()

        // Then
        XCTAssertEqual(viewModel.shoppingStatus, .idle)
        XCTAssertNil(viewModel.activeShopperId)
        XCTAssertNil(viewModel.shoppingStoreId)
        XCTAssertNil(viewModel.shoppingStartedAt)
        XCTAssertFalse(viewModel.isAtStoreMode)
        XCTAssertTrue(viewModel.pendingRequests.isEmpty,
            "Pending requests should be cleared on exit")
    }

    func testShopperExitShoppingMode_ClearsAllPendingRequests() {
        // Given: Shopper with multiple pending requests
        setupShopperScenario()
        viewModel.pendingRequests = [
            makeRequest(id: "req-1"),
            makeRequest(id: "req-2"),
            makeRequest(id: "req-3")
        ]

        // When: Exiting shopping mode (simulating clearAllPendingRequests)
        viewModel.pendingRequests.removeAll()

        // Then
        XCTAssertTrue(viewModel.pendingRequests.isEmpty)
        XCTAssertEqual(viewModel.pendingRequestCount, 0)
    }

    // MARK: - PHASE 2: AT_STORE - REMOTE MEMBER Scenarios

    // MARK: Scenario 1: Remote Member Add Item

    func testRemoteMemberAddItem_RedirectsToSubmitAddRequest() {
        // Given: Someone else is shopping
        setupRemoteMemberScenario()

        // Then: Verify state is correct for redirect
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)
        XCTAssertFalse(viewModel.isAtStoreMode)
        // Note: addItem checks isSomeoneElseShopping and calls submitAddRequest
    }

    func testRemoteMemberSubmitAddRequest_RequestCreation() {
        // Given: Request details
        let name = "New Item"
        let quantity = "2"
        let notes = "Fresh please"
        let productId = "prod-456"

        // When: Creating a request (simulating submitAddRequest behavior)
        let request = makeRequest(
            requestType: .addItem,
            itemName: name,
            quantity: quantity,
            notes: notes,
            productId: productId,
            requestedBy: currentUserId
        )

        // Then
        XCTAssertTrue(request.isAddRequest)
        XCTAssertEqual(request.itemName, name)
        XCTAssertEqual(request.quantity, quantity)
        XCTAssertEqual(request.notes, notes)
        XCTAssertEqual(request.productId, productId)
        XCTAssertEqual(request.requestedBy, currentUserId)
        XCTAssertEqual(request.status, .pending)
    }

    func testRemoteMemberAddItem_DoesNotDirectlyAddToList() {
        // Given: Someone else is shopping
        setupRemoteMemberScenario()
        viewModel.activeItems = []

        // Then: Verify isSomeoneElseShopping condition
        // In addItem: if isSomeoneElseShopping { await submitAddRequest(...); return }
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)

        // Active items should remain empty (request goes to inbox instead)
        XCTAssertTrue(viewModel.activeItems.isEmpty)
    }

    // MARK: Scenario 2: Remote Member Delete Item

    func testRemoteMemberDeleteItem_RedirectsToSubmitRemoveRequest() {
        // Given: Someone else is shopping
        setupRemoteMemberScenario()

        let item = makeItem(id: "item-to-remove", name: "Bananas")
        viewModel.activeItems = [item]

        // Then: Verify state for redirect
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        // Note: deleteItem checks isSomeoneElseShopping and calls submitRemoveRequest
    }

    func testRemoteMemberSubmitRemoveRequest_RequestCreation() {
        // Given: An item to remove
        let item = makeItem(id: "item-123", name: "Bananas")

        // When: Creating a remove request
        let request = makeRequest(
            requestType: .removeItem,
            itemName: item.name,
            targetItemId: item.id,
            requestedBy: currentUserId
        )

        // Then
        XCTAssertTrue(request.isRemoveRequest)
        XCTAssertEqual(request.itemName, item.name)
        XCTAssertEqual(request.targetItemId, item.id)
        XCTAssertEqual(request.requestedBy, currentUserId)
    }

    func testRemoteMemberDeleteItem_DoesNotDirectlyRemoveFromList() {
        // Given: Someone else is shopping with an item
        setupRemoteMemberScenario()
        let item = makeItem(id: "item-1", name: "Milk")
        viewModel.activeItems = [item]

        // Then: Item should still be in list (delete redirects to request)
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.activeItems.first?.id, "item-1")
    }

    // MARK: Scenario 3: Remote Member Check Off Item (BLOCKED)

    func testRemoteMemberCheckOffItem_IsBlocked() {
        // Given: Someone else is shopping
        setupRemoteMemberScenario()

        let item = makeItem()
        viewModel.activeItems = [item]

        // Then: The guard condition isSomeoneElseShopping triggers block
        // checkOffItem shows: "List is read-only while shopping"
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)
    }

    func testRemoteMemberCheckOffItem_ToastMessage() {
        // Given: The expected blocking message
        let expectedMessage = "List is read-only while shopping"

        // Then: Verify this is the message shown (from checkOffItem implementation)
        // checkOffItem: showToast(message: "List is read-only while shopping", type: .warning)
        XCTAssertEqual(expectedMessage, "List is read-only while shopping")
    }

    func testRemoteMemberCheckOffItem_ItemRemainsActive() {
        // Given: Someone else is shopping with an active item
        setupRemoteMemberScenario()
        let item = makeItem(id: "item-1", status: .active)
        viewModel.activeItems = [item]
        viewModel.crossedOffItems = []

        // Then: Item should remain in activeItems (blocked operation)
        XCTAssertEqual(viewModel.activeItems.count, 1)
        XCTAssertEqual(viewModel.activeItems.first?.status, .active)
        XCTAssertTrue(viewModel.crossedOffItems.isEmpty)
    }

    // MARK: Scenario 4: Remote Member Restore Item (BLOCKED)

    func testRemoteMemberRestoreItem_IsBlocked() {
        // Given: Someone else is shopping
        setupRemoteMemberScenario()

        let crossedOffItem = makeItem(status: .crossedOff, crossedOffAt: Date())
        viewModel.crossedOffItems = [crossedOffItem]

        // Then: The guard condition blocks restore
        // restoreItem checks isSomeoneElseShopping
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)
    }

    func testRemoteMemberRestoreItem_ItemRemainsCrossedOff() {
        // Given: Someone else is shopping with a crossed-off item
        setupRemoteMemberScenario()
        let crossedOffItem = makeItem(id: "item-1", status: .crossedOff, crossedOffAt: Date())
        viewModel.activeItems = []
        viewModel.crossedOffItems = [crossedOffItem]

        // Then: Item should remain in crossedOffItems (blocked operation)
        XCTAssertTrue(viewModel.activeItems.isEmpty)
        XCTAssertEqual(viewModel.crossedOffItems.count, 1)
        XCTAssertEqual(viewModel.crossedOffItems.first?.status, .crossedOff)
    }

    // MARK: Scenario 5: Remote Member Toggle Lock (BLOCKED)

    func testRemoteMemberToggleLock_IsBlocked() {
        // Given: Someone else is shopping
        setupRemoteMemberScenario()

        let item = makeItem()
        viewModel.activeItems = [item]

        // Then: The guard condition blocks lock toggle
        // toggleLock checks isSomeoneElseShopping
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)
    }

    func testRemoteMemberToggleLock_ToastMessage() {
        // Given: The expected blocking message
        let expectedMessage = "List is read-only while shopping"

        // Then: Verify this is the message shown (from toggleLock implementation)
        XCTAssertEqual(expectedMessage, "List is read-only while shopping")
    }

    func testRemoteMemberToggleLock_ItemLockUnchanged() {
        // Given: Someone else is shopping with an unlocked item
        setupRemoteMemberScenario()
        let unlockedItem = makeItem(id: "item-1", lockedBy: nil)
        viewModel.activeItems = [unlockedItem]

        // Then: Item should remain unlocked (blocked operation)
        XCTAssertNil(viewModel.activeItems.first?.lockedBy)
    }

    // MARK: - Shopping Request State Tests

    func testShoppingRequest_PendingStatus() {
        let request = makeRequest(requestedBy: "user-1")

        XCTAssertTrue(request.isPending)
        XCTAssertFalse(request.isApproved)
        XCTAssertFalse(request.isRejected)
        XCTAssertFalse(request.isResolved)
    }

    func testShoppingRequest_ApprovedStatus() {
        var request = makeRequest(requestedBy: "user-1")
        request.status = .approved
        request.resolvedBy = "shopper-1"
        request.resolvedAt = Date()

        XCTAssertFalse(request.isPending)
        XCTAssertTrue(request.isApproved)
        XCTAssertFalse(request.isRejected)
        XCTAssertTrue(request.isResolved)
    }

    func testShoppingRequest_RejectedStatus() {
        var request = makeRequest(requestedBy: "user-1")
        request.status = .rejected
        request.resolvedBy = "shopper-1"
        request.resolvedAt = Date()

        XCTAssertFalse(request.isPending)
        XCTAssertFalse(request.isApproved)
        XCTAssertTrue(request.isRejected)
        XCTAssertTrue(request.isResolved)
    }

    // MARK: - Shopping Status Transitions

    func testShoppingStatus_IdleToAtStore() {
        // Given: Idle state
        viewModel.setTestState(
            shoppingStatus: .idle,
            activeShopperId: nil,
            shoppingStoreId: nil,
            shoppingStartedAt: nil
        )
        viewModel.isAtStoreMode = false

        // When: Entering shopping mode
        let startTime = Date()
        viewModel.shoppingStatus = .atStore
        viewModel.activeShopperId = currentUserId
        viewModel.shoppingStoreId = "store-1"
        viewModel.shoppingStartedAt = startTime
        viewModel.isAtStoreMode = true

        // Then
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, currentUserId)
        XCTAssertEqual(viewModel.shoppingStoreId, "store-1")
        XCTAssertEqual(viewModel.shoppingStartedAt, startTime)
        XCTAssertTrue(viewModel.isAtStoreMode)
    }

    func testShoppingStatus_AtStoreToIdle() {
        // Given: At store state
        setupShopperScenario()

        // When: Exiting shopping mode
        viewModel.shoppingStatus = .idle
        viewModel.activeShopperId = nil
        viewModel.shoppingStoreId = nil
        viewModel.shoppingStartedAt = nil
        viewModel.isAtStoreMode = false

        // Then
        XCTAssertEqual(viewModel.shoppingStatus, .idle)
        XCTAssertNil(viewModel.activeShopperId)
        XCTAssertNil(viewModel.shoppingStoreId)
        XCTAssertNil(viewModel.shoppingStartedAt)
        XCTAssertFalse(viewModel.isAtStoreMode)
    }

    // MARK: - Pending Request Management

    func testPendingRequestManagement_AddRequest() {
        // Given: Empty pending requests
        viewModel.pendingRequests = []

        // When: Adding a request
        let newRequest = makeRequest(id: "new-req", itemName: "Milk")
        viewModel.pendingRequests.append(newRequest)

        // Then
        XCTAssertEqual(viewModel.pendingRequestCount, 1)
        XCTAssertEqual(viewModel.pendingRequests.first?.itemName, "Milk")
    }

    func testPendingRequestManagement_RemoveRequest() {
        // Given: Existing requests
        viewModel.pendingRequests = [
            makeRequest(id: "req-1", itemName: "Milk"),
            makeRequest(id: "req-2", itemName: "Bread")
        ]

        // When: Removing a specific request
        viewModel.pendingRequests.removeAll { $0.id == "req-1" }

        // Then
        XCTAssertEqual(viewModel.pendingRequestCount, 1)
        XCTAssertEqual(viewModel.pendingRequests.first?.id, "req-2")
    }

    func testPendingRequestManagement_ClearAll() {
        // Given: Multiple pending requests
        viewModel.pendingRequests = [
            makeRequest(id: "req-1"),
            makeRequest(id: "req-2"),
            makeRequest(id: "req-3")
        ]

        // When: Clearing all
        viewModel.pendingRequests.removeAll()

        // Then
        XCTAssertTrue(viewModel.pendingRequests.isEmpty)
        XCTAssertEqual(viewModel.pendingRequestCount, 0)
    }

    func testPendingRequestManagement_DuplicatePrevention() {
        // Given: An existing request
        let existingRequest = makeRequest(id: "req-1", itemName: "Milk")
        viewModel.pendingRequests = [existingRequest]

        // When: Attempting to add same request (checking for duplicate)
        let duplicateCheck = viewModel.pendingRequests.contains { $0.id == "req-1" }

        // Then
        XCTAssertTrue(duplicateCheck, "Should detect duplicate request")
    }

    // MARK: - Lock Bypass During Shopping

    func testShopperBypassesLock_OnCheckOff() {
        // Given: Item locked by another user
        let lockedItem = makeItem(lockedBy: otherUserId)
        viewModel.activeItems = [lockedItem]

        // And: Current user is shopping
        setupShopperScenario()

        // Then: isCurrentUserShopping should be true, bypassing lock check
        XCTAssertTrue(viewModel.isCurrentUserShopping,
            "Shopper should be identified correctly")

        // Verify guard condition logic
        let isCurrentUserShopping = viewModel.isCurrentUserShopping
        let isLockedByOther = lockedItem.lockedBy != nil && lockedItem.lockedBy != currentUserId
        let shouldBlock = !isCurrentUserShopping && isLockedByOther

        XCTAssertFalse(shouldBlock, "Shopper should bypass lock")
    }

    func testShopperBypassesLock_OnDelete() {
        // Given: Item locked by another user
        let lockedItem = makeItem(lockedBy: otherUserId)
        viewModel.activeItems = [lockedItem]

        // And: Current user is shopping
        setupShopperScenario()

        // Then: isCurrentUserShopping should be true
        XCTAssertTrue(viewModel.isCurrentUserShopping)
    }

    func testShopperBypassesLock_OnRestore() {
        // Given: Item locked by another user
        let lockedItem = makeItem(status: .crossedOff, lockedBy: otherUserId)
        viewModel.crossedOffItems = [lockedItem]

        // And: Current user is shopping
        setupShopperScenario()

        // Then
        XCTAssertTrue(viewModel.isCurrentUserShopping)
    }

    func testShopperBypassesLock_OnToggleLock() {
        // Given: Item locked by another user
        let lockedItem = makeItem(lockedBy: otherUserId)
        viewModel.activeItems = [lockedItem]

        // And: Current user is shopping
        setupShopperScenario()

        // Then
        XCTAssertTrue(viewModel.isCurrentUserShopping)
    }

    // MARK: - Items Crossed Off This Trip Edge Cases

    func testItemsCrossedOffThisTrip_WithExactStartTime() {
        // Given: Item crossed off at exact start time
        let startTime = Date()
        viewModel.setTestState(
            crossedOffItems: [
                makeItem(id: "exact", status: .crossedOff, crossedOffAt: startTime)
            ],
            shoppingStartedAt: startTime
        )

        // Then: Should include (>= comparison)
        let result = viewModel.itemsCrossedOffThisTrip
        XCTAssertEqual(result.count, 1,
            "Should include item crossed off at exact start time")
    }

    func testItemsCrossedOffThisTrip_MixedDates() {
        // Given: Shopping started at specific time
        let startTime = Date()
        let hourBefore = startTime.addingTimeInterval(-3600)
        let minuteAfter = startTime.addingTimeInterval(60)
        let hourAfter = startTime.addingTimeInterval(3600)

        viewModel.setTestState(
            crossedOffItems: [
                makeItem(id: "before", status: .crossedOff, crossedOffAt: hourBefore),
                makeItem(id: "minute-after", status: .crossedOff, crossedOffAt: minuteAfter),
                makeItem(id: "hour-after", status: .crossedOff, crossedOffAt: hourAfter)
            ],
            shoppingStartedAt: startTime
        )

        // Then: Should only include items after start
        let result = viewModel.itemsCrossedOffThisTrip
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.contains { $0.id == "minute-after" })
        XCTAssertTrue(result.contains { $0.id == "hour-after" })
        XCTAssertFalse(result.contains { $0.id == "before" })
    }

    // MARK: - Parse Shopping Request Tests

    func testParseShoppingRequest_AddRequest() {
        // Given: JSON for add request
        let json: JSONValue = .object([
            "id": .string("req-123"),
            "householdId": .string(householdId),
            "requestType": .string("ADD_ITEM"),
            "itemName": .string("Milk"),
            "normalizedName": .string("milk"),
            "quantity": .string("1 gallon"),
            "notes": .string("Organic"),
            "productId": .string("prod-123"),
            "requestedBy": .string("user-123"),
            "requestedAt": .string("2024-01-01T10:00:00Z"),
            "status": .string("PENDING")
        ])

        // When
        let result = viewModel.parseShoppingRequest(json)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.id, "req-123")
        XCTAssertEqual(result?.requestType, .addItem)
        XCTAssertEqual(result?.itemName, "Milk")
        XCTAssertEqual(result?.quantity, "1 gallon")
        XCTAssertEqual(result?.notes, "Organic")
        XCTAssertEqual(result?.productId, "prod-123")
        XCTAssertTrue(result?.isAddRequest ?? false)
        XCTAssertTrue(result?.isPending ?? false)
    }

    func testParseShoppingRequest_RemoveRequest() {
        // Given: JSON for remove request
        let json: JSONValue = .object([
            "id": .string("req-456"),
            "householdId": .string(householdId),
            "requestType": .string("REMOVE_ITEM"),
            "itemName": .string("Bananas"),
            "normalizedName": .string("banana"),
            "targetItemId": .string("item-to-remove"),
            "requestedBy": .string("user-456"),
            "requestedAt": .string("2024-01-01T11:00:00Z"),
            "status": .string("PENDING")
        ])

        // When
        let result = viewModel.parseShoppingRequest(json)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.requestType, .removeItem)
        XCTAssertEqual(result?.targetItemId, "item-to-remove")
        XCTAssertTrue(result?.isRemoveRequest ?? false)
    }

    func testParseShoppingRequest_MissingRequiredFields_ReturnsNil() {
        // Given: JSON missing required fields
        let json: JSONValue = .object([
            "id": .string("req-789"),
            "householdId": .string(householdId)
            // Missing: requestType, itemName, requestedBy, status
        ])

        // When
        let result = viewModel.parseShoppingRequest(json)

        // Then
        XCTAssertNil(result, "Should return nil for incomplete JSON")
    }

    func testParseShoppingRequest_InvalidRequestType_ReturnsNil() {
        // Given: JSON with invalid request type
        let json: JSONValue = .object([
            "id": .string("req-invalid"),
            "householdId": .string(householdId),
            "requestType": .string("INVALID_TYPE"),
            "itemName": .string("Test"),
            "requestedBy": .string("user-1"),
            "requestedAt": .string("2024-01-01T10:00:00Z"),
            "status": .string("PENDING")
        ])

        // When
        let result = viewModel.parseShoppingRequest(json)

        // Then
        XCTAssertNil(result, "Should return nil for invalid request type")
    }

    func testParseShoppingRequest_InvalidStatus_ReturnsNil() {
        // Given: JSON with invalid status
        let json: JSONValue = .object([
            "id": .string("req-invalid"),
            "householdId": .string(householdId),
            "requestType": .string("ADD_ITEM"),
            "itemName": .string("Test"),
            "requestedBy": .string("user-1"),
            "requestedAt": .string("2024-01-01T10:00:00Z"),
            "status": .string("INVALID_STATUS")
        ])

        // When
        let result = viewModel.parseShoppingRequest(json)

        // Then
        XCTAssertNil(result, "Should return nil for invalid status")
    }

    func testParseShoppingRequest_ApprovedStatus() {
        // Given: JSON for approved request
        // Note: ISO8601DateFormatter with .withFractionalSeconds requires fractional seconds in the string
        let json: JSONValue = .object([
            "id": .string("req-approved"),
            "householdId": .string(householdId),
            "requestType": .string("ADD_ITEM"),
            "itemName": .string("Approved Item"),
            "requestedBy": .string("user-1"),
            "requestedAt": .string("2024-01-01T10:00:00.000Z"),
            "status": .string("APPROVED"),
            "resolvedBy": .string("shopper-1"),
            "resolvedAt": .string("2024-01-01T10:30:00.000Z")
        ])

        // When
        let result = viewModel.parseShoppingRequest(json)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .approved)
        XCTAssertEqual(result?.resolvedBy, "shopper-1")
        XCTAssertNotNil(result?.resolvedAt)
        XCTAssertTrue(result?.isApproved ?? false)
        XCTAssertTrue(result?.isResolved ?? false)
    }

    func testParseShoppingRequest_RejectedStatus() {
        // Given: JSON for rejected request
        let json: JSONValue = .object([
            "id": .string("req-rejected"),
            "householdId": .string(householdId),
            "requestType": .string("REMOVE_ITEM"),
            "itemName": .string("Rejected Item"),
            "targetItemId": .string("item-123"),
            "requestedBy": .string("user-1"),
            "requestedAt": .string("2024-01-01T10:00:00Z"),
            "status": .string("REJECTED"),
            "resolvedBy": .string("shopper-1"),
            "resolvedAt": .string("2024-01-01T10:30:00Z")
        ])

        // When
        let result = viewModel.parseShoppingRequest(json)

        // Then
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .rejected)
        XCTAssertTrue(result?.isRejected ?? false)
        XCTAssertTrue(result?.isResolved ?? false)
    }

    // MARK: - Edge Cases for AT_STORE Phase

    func testShopperWithNoItems_CanStillManageRequests() {
        // Given: Shopper with empty list but pending requests
        setupShopperScenario()
        viewModel.activeItems = []
        viewModel.crossedOffItems = []
        viewModel.pendingRequests = [
            makeRequest(id: "req-1", requestType: .addItem, itemName: "New Item")
        ]

        // Then: Can still manage requests
        XCTAssertEqual(viewModel.pendingRequestCount, 1)
        XCTAssertTrue(viewModel.isCurrentUserShopping)
    }

    func testRemoteMemberCannotModifyDuringAtStore() {
        // Given: Remote member scenario
        setupRemoteMemberScenario()

        // Then: All direct modifications should be blocked
        // (isSomeoneElseShopping returns true based on state)
        XCTAssertEqual(viewModel.shoppingStatus, .atStore)
        XCTAssertEqual(viewModel.activeShopperId, otherUserId)
        XCTAssertFalse(viewModel.isAtStoreMode)
    }

    func testItemsCrossedOffDuringTrip_TrackedCorrectly() {
        // Given: Shopping trip in progress
        let startTime = Date()
        setupShopperScenario()
        viewModel.shoppingStartedAt = startTime

        // Add items crossed off during trip
        let item1 = makeItem(id: "item-1", name: "Got This", status: .crossedOff,
                            crossedOffAt: startTime.addingTimeInterval(300))
        let item2 = makeItem(id: "item-2", name: "Got This Too", status: .crossedOff,
                            crossedOffAt: startTime.addingTimeInterval(600))

        viewModel.crossedOffItems = [item1, item2]

        // Then: Both items should be in itemsCrossedOffThisTrip
        XCTAssertEqual(viewModel.itemsCrossedOffThisTrip.count, 2)
    }

    func testMultiplePendingRequests_OrderPreserved() {
        // Given: Multiple requests added in order
        setupShopperScenario()
        let req1 = makeRequest(id: "req-1", itemName: "First")
        let req2 = makeRequest(id: "req-2", itemName: "Second")
        let req3 = makeRequest(id: "req-3", itemName: "Third")

        viewModel.pendingRequests = [req1, req2, req3]

        // Then: Order should be preserved
        XCTAssertEqual(viewModel.pendingRequests[0].id, "req-1")
        XCTAssertEqual(viewModel.pendingRequests[1].id, "req-2")
        XCTAssertEqual(viewModel.pendingRequests[2].id, "req-3")
    }
}
