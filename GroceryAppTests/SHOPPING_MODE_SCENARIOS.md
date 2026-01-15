# Shopping Mode Scenarios & Test Coverage

## Overview
This document outlines all scenarios for household members participating in shopping list management, both before and during active shopping.

---

## PHASE 1: IDLE (Before Shopping - List Building)

When `shoppingStatus == .idle`, all household members have equal access to modify the list.

### Computed Properties
| Property | Value |
|----------|-------|
| `isCurrentUserShopping` | `false` |
| `isSomeoneElseShopping` | `false` |
| `shoppingStatus` | `.idle` |

### Scenarios

| # | Scenario | Actor | Action | Expected Behavior | Test Coverage |
|---|----------|-------|--------|-------------------|---------------|
| 1 | Add item | Any member | `addItem()` | Item added to activeItems | ✅ |
| 2 | Add duplicate item | Any member | `addItem()` | Shows warning, not added | ✅ |
| 3 | Add item in crossed-off | Any member | `addItem()` | Shows "tap to restore" warning | ✅ |
| 4 | Delete item | Any member | `deleteItem()` | Item removed | ✅ |
| 5 | Cross off item | Any member | `checkOffItem()` | Item moves to crossedOffItems | ✅ |
| 6 | Restore item | Any member | `restoreItem()` | Item moves back to activeItems | ✅ |
| 7 | Lock item | Any member | `toggleLock()` | Item locked by user | ✅ |
| 8 | Unlock own lock | Lock owner | `toggleLock()` | Item unlocked | ✅ |
| 9 | Unlock other's lock | Non-owner | `toggleLock()` | Blocked - shows warning | ✅ |
| 10 | Modify locked item | Non-owner | Any modify action | Blocked - shows warning | ✅ |
| 11 | Add reaction | Any member | `toggleReaction()` | Reaction added | ✅ |
| 12 | Enter shopping mode | Any member | `enterShoppingMode()` | Status → AT_STORE | ✅ |

---

## PHASE 2: AT_STORE (Active Shopping)

When `shoppingStatus == .atStore`, behavior differs based on who is shopping.

### For the SHOPPER (`isCurrentUserShopping == true`)

The shopper has full control over the list and bypasses lock checks.

| # | Scenario | Action | Expected Behavior | Test Coverage |
|---|----------|--------|-------------------|---------------|
| 1 | Add item | `addItem()` | Item added directly | ✅ |
| 2 | Delete item | `deleteItem()` | Item removed directly | ✅ |
| 3 | Cross off item | `checkOffItem()` | Item moves to crossedOffItems | ✅ |
| 4 | Restore item | `restoreItem()` | Item moves back to activeItems | ✅ |
| 5 | Cross off locked item | `checkOffItem()` | Bypasses lock - item crossed off | ✅ |
| 6 | Approve ADD request | `approveRequest()` | Item added, request deleted | ✅ |
| 7 | Approve REMOVE request | `approveRequest()` | Item deleted, request deleted | ✅ |
| 8 | Reject request | `rejectRequest()` | Request deleted only | ✅ |
| 9 | Exit shopping mode | `exitShoppingMode()` | Status → IDLE, clears requests | ✅ |

### For REMOTE MEMBERS (`isSomeoneElseShopping == true`)

Remote members see a **read-only** list. They can only submit requests.

| # | Scenario | Action | Expected Behavior | Test Coverage |
|---|----------|--------|-------------------|---------------|
| 1 | Add item | `addItem()` | Redirects to `submitAddRequest()` | ✅ |
| 2 | Delete item | `deleteItem()` | Redirects to `submitRemoveRequest()` | ✅ |
| 3 | Cross off item | `checkOffItem()` | **BLOCKED** - "List is read-only while shopping" | ✅ |
| 4 | Restore item | `restoreItem()` | **BLOCKED** - "List is read-only while shopping" | ✅ |
| 5 | Lock/unlock item | `toggleLock()` | **BLOCKED** - "List is read-only while shopping" | ✅ |

---

## Request/Approval Inbox System

### Request Types
- `ADD_ITEM` - Request to add a new item
- `REMOVE_ITEM` - Request to remove an existing item

### Request States
- `PENDING` - Awaiting shopper decision
- `APPROVED` - Shopper approved (item added/removed)
- `REJECTED` - Shopper rejected (no action taken)

### Notifications
- **Visual**: Bell icon shakes when new request arrives
- **Haptic**: Impact feedback on new request
- **Sound**: System sound plays
- **Reminder**: Every 45 seconds if pending requests exist

### Request Lifecycle
1. Remote member attempts add/delete during active shopping
2. Request created with `PENDING` status
3. Shopper notified via visual/haptic/sound
4. Shopper opens inbox and approves/rejects
5. If approved: action executed (add/delete item)
6. Request removed from pending list
7. When shopping ends: all pending requests cleared

---

## Test Files

| File | Test Count | Focus |
|------|------------|-------|
| `ShoppingModeTests.swift` | 116 | IDLE & AT_STORE phase scenarios |
| `ShoppingListViewModelTests.swift` | 29 | Parsing, sorting, version handling |
| `GroceryItemTests.swift` | 31 | Model properties, encoding/decoding |
| `ProductTests.swift` | 21 | Product model tests |
| `UserTests.swift` | 24 | User model tests |
| `AuthErrorParsingTests.swift` | 22 | Auth error handling |

**Total: 243 tests, 0 failures**

---

## Code Coverage

| File | Coverage |
|------|----------|
| User.swift | 100% |
| Product.swift | 100% |
| GroceryItem.swift | 59.71% |
| ShoppingRequest.swift | 43.37% |
| ShoppingListViewModel.swift | 12.15% |

Note: ViewModel coverage is limited because most methods require async network calls. Tests focus on synchronous guard conditions and state management logic.
