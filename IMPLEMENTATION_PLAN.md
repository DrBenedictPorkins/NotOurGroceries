# User & Household Management Implementation Plan

## Overview

Implement authentication gate, auto-household creation on signup, invite system with email, and real-time subscriptions for NotOurGroceries iOS app.

---

## Agent Parallelization Strategy

This implementation should use multiple agents working in parallel to maximize efficiency. The batches below are designed to be executed concurrently where dependencies allow.

### Parallel Execution Groups

**Group A (can run in parallel):**
- Agent 1: Auth Gate Schema + iOS Views (Batch 1)
- Agent 2: Invite System Lambda Functions (Batch 2)
- Agent 3: Subscription Service (Batch 4)

**Group B (after Group A completes):**
- Agent 1: Invite System iOS UI (Batch 3) - depends on Batch 2 mutations
- Agent 2: Integration testing and polish

### Agent Task Assignment

When starting implementation, launch these Task agents in parallel:

```
Task 1 (subagent_type: "apple-dev-pro"):
  "Implement auth gate for NotOurGroceries - create RootView.swift, AuthGateView.swift,
   HouseholdSetupView.swift, update GroceryAppApp.swift, add checkHouseholdNameAvailable
   to AmplifyService"

Task 2 (subagent_type: "general-purpose"):
  "Implement invite system Lambda functions - regenerateInviteCodeFunction,
   joinHouseholdFunction, sendInviteEmailFunction, update backend.ts with permissions"

Task 3 (subagent_type: "apple-dev-pro"):
  "Implement SubscriptionService.swift for real-time GraphQL subscriptions,
   update ShoppingListViewModel with subscription handlers"
```

---

## Requirements Summary

| Feature | Requirement |
|---------|-------------|
| Auth Gate | Force login/signup before app access |
| Household Creation | Prompt for unique name after signup, auto-create and join |
| Invite Codes | 24-hour expiration, regeneratable by any member |
| Invite Delivery | Manual copy/share AND in-app email via SES |
| Join Flow | Warn about leaving current household, session updates immediately |
| Real-time Sync | Initial refresh on join, then WebSocket subscriptions |
| UI Location | Dedicated Household tab |

---

## Phase 1: Auth Gate & Signup Flow

### 1.1 Schema Changes

**File:** `amplify/data/resource.ts`

Add secondary index on `Household.name` for uniqueness validation:

```typescript
// Line ~92-94, add to secondaryIndexes:
.secondaryIndexes((index) => [
  index('inviteCode'),
  index('name').queryField('listHouseholdByName'),  // NEW
])
```

### 1.2 New Swift Files

| File | Purpose |
|------|---------|
| `Views/Auth/AuthGateView.swift` | Full-screen login/signup (extracted from SettingsView) |
| `Views/Auth/HouseholdSetupView.swift` | Prompt for unique household name after signup |
| `Views/RootView.swift` | State router: AuthGate -> HouseholdSetup -> ContentView |

### 1.3 Modified Swift Files

| File | Changes |
|------|---------|
| `GroceryAppApp.swift` | Replace `ContentView()` with `RootView()` |
| `Services/AmplifyService.swift` | Add `checkHouseholdNameAvailable()` method |
| `Views/SettingsView.swift` | Remove auth forms (users can't reach without auth) |
| `Views/HouseholdView.swift` | Remove not-authenticated state |

### 1.4 User Flow

```
App Launch -> Check Auth
    |-- Not Authenticated -> AuthGateView (login/signup)
    |       |-- After email verification -> Sign in automatically
    |
    |-- Authenticated -> Check householdId
            |-- No household -> HouseholdSetupView (name prompt)
            |       |-- Creates household, auto-joins user
            |
            |-- Has household -> ContentView (TabView)
```

### 1.5 RootView Implementation Pattern

```swift
struct RootView: View {
    @EnvironmentObject var amplifyService: AmplifyService

    var body: some View {
        Group {
            if !amplifyService.isConfigured {
                SplashView()
            } else if !amplifyService.isAuthenticated {
                AuthGateView()
            } else if amplifyService.currentHouseholdId == nil {
                HouseholdSetupView()
            } else {
                ContentView()
            }
        }
    }
}
```

---

## Phase 2: Invite System

### 2.1 Schema Changes

**File:** `amplify/data/resource.ts`

Add expiration field to Household:

```typescript
Household: a.model({
  name: a.string().required(),
  inviteCode: a.string().required(),
  inviteCodeExpiresAt: a.datetime().required(),  // NEW
  // ... rest unchanged
})
```

### 2.2 New Lambda Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `regenerateInviteCodeFunction` | `amplify/data/regenerateInviteCodeFunction/handler.ts` | Generate new 6-char code, set 24h expiration |
| `sendInviteEmailFunction` | `amplify/data/sendInviteEmailFunction/handler.ts` | Send invite via AWS SES |
| `joinHouseholdFunction` | `amplify/data/joinHouseholdFunction/handler.ts` | Validate code not expired, switch user's household |

### 2.3 New GraphQL Mutations

```typescript
// Add to resource.ts after existing mutations

regenerateInviteCode: a
  .mutation()
  .arguments({ householdId: a.id().required() })
  .returns(a.customType({
    inviteCode: a.string().required(),
    expiresAt: a.datetime().required(),
  }))
  .authorization((allow) => [allow.authenticated()])
  .handler(a.handler.function(regenerateInviteCodeFunction)),

sendInviteEmail: a
  .mutation()
  .arguments({
    householdId: a.id().required(),
    recipientEmail: a.string().required(),
    senderName: a.string().required(),
  })
  .returns(a.customType({
    success: a.boolean().required(),
    message: a.string(),
  }))
  .authorization((allow) => [allow.authenticated()])
  .handler(a.handler.function(sendInviteEmailFunction)),

joinHousehold: a
  .mutation()
  .arguments({ inviteCode: a.string().required() })
  .returns(a.customType({
    householdId: a.id().required(),
    householdName: a.string().required(),
    previousHouseholdId: a.id(),
  }))
  .authorization((allow) => [allow.authenticated()])
  .handler(a.handler.function(joinHouseholdFunction)),
```

### 2.4 Backend Config Updates

**File:** `amplify/backend.ts`

```typescript
// Add imports
import {
  // ... existing imports
  regenerateInviteCodeFunction,
  sendInviteEmailFunction,
  joinHouseholdFunction,
} from './data/resource';

// Register in defineBackend
const backend = defineBackend({
  // ... existing
  regenerateInviteCodeFunction,
  sendInviteEmailFunction,
  joinHouseholdFunction,
});

// Add Lambda permissions
const regenerateInviteCodeLambda = backend.regenerateInviteCodeFunction.resources.lambda as Function;
const sendInviteEmailLambda = backend.sendInviteEmailFunction.resources.lambda as Function;
const joinHouseholdLambda = backend.joinHouseholdFunction.resources.lambda as Function;

// regenerateInviteCodeFunction
addEnvVars(regenerateInviteCodeLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
});
householdTable.grantReadWriteData(regenerateInviteCodeLambda);
userTable.grantReadData(regenerateInviteCodeLambda);

// sendInviteEmailFunction
addEnvVars(sendInviteEmailLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
  SES_SOURCE_EMAIL: 'noreply@yourdomain.com',  // Configure this
});
householdTable.grantReadData(sendInviteEmailLambda);
userTable.grantReadData(sendInviteEmailLambda);
sendInviteEmailLambda.addToRolePolicy(new PolicyStatement({
  actions: ['ses:SendEmail', 'ses:SendRawEmail'],
  resources: ['*'],
}));

// joinHouseholdFunction
addEnvVars(joinHouseholdLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
});
householdTable.grantReadData(joinHouseholdLambda);
userTable.grantReadWriteData(joinHouseholdLambda);
joinHouseholdLambda.addToRolePolicy(new PolicyStatement({
  actions: ['dynamodb:Query'],
  resources: [`${householdTable.tableArn}/index/*`],
}));
```

### 2.5 AWS SES Setup (Manual Steps)

1. Go to AWS SES Console
2. Verify sender email or domain
3. Request production access if in sandbox mode
4. Update `SES_SOURCE_EMAIL` in backend.ts

### 2.6 New Swift Files

| File | Purpose |
|------|---------|
| `Views/HouseholdInviteView.swift` | Sheet with invite code display, copy button, share sheet, email form |

### 2.7 Modified Swift Files

| File | Changes |
|------|---------|
| `Services/AmplifyService.swift` | Add `regenerateInviteCode()`, `sendInviteEmail()`, `joinHouseholdWithWarning()` |
| `Views/HouseholdView.swift` | Add "Invite Members" button, leave household confirmation alert |

---

## Phase 3: Real-Time Subscriptions

### 3.1 Backend

Amplify Gen 2 auto-generates subscriptions for all models:
- `onCreateGroceryItem`
- `onUpdateGroceryItem`
- `onDeleteGroceryItem`

**No schema changes needed** - subscriptions fire when mutations return `GroceryItem`.

### 3.2 New Swift Files

| File | Purpose |
|------|---------|
| `Services/SubscriptionService.swift` | Singleton managing WebSocket subscriptions, publishes events via Combine |

### 3.3 SubscriptionService Pattern

```swift
@MainActor
class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()

    @Published var lastCreatedItem: GroceryItem?
    @Published var lastUpdatedItem: GroceryItem?
    @Published var lastDeletedItemId: String?

    private var createTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var deleteTask: Task<Void, Never>?
    private var currentHouseholdId: String?

    func subscribeToHousehold(_ householdId: String) {
        unsubscribeAll()
        currentHouseholdId = householdId
        subscribeToCreate(householdId: householdId)
        subscribeToUpdate(householdId: householdId)
        subscribeToDelete(householdId: householdId)
    }

    func unsubscribeAll() {
        createTask?.cancel()
        updateTask?.cancel()
        deleteTask?.cancel()
    }

    // Subscribe to each event type with householdId filtering
}
```

### 3.4 Modified Swift Files

| File | Changes |
|------|---------|
| `ViewModels/ShoppingListViewModel.swift` | Add subscription observation via Combine, event handlers |
| `Views/ShoppingListView.swift` | Call `setupSubscriptions()` on appear, `teardownSubscriptions()` on disappear |
| `Services/AmplifyService.swift` | Post `Notification.Name.householdChanged` when joining new household |

### 3.5 ViewModel Integration Pattern

```swift
// In ShoppingListViewModel
import Combine

private var subscriptionCancellables = Set<AnyCancellable>()

func setupSubscriptions() {
    guard let householdId = householdId else { return }

    SubscriptionService.shared.subscribeToHousehold(householdId)

    SubscriptionService.shared.$lastCreatedItem
        .compactMap { $0 }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] item in
            self?.handleItemCreated(item)
        }
        .store(in: &subscriptionCancellables)

    // Similar for update and delete...
}

private func handleItemCreated(_ item: GroceryItem) {
    // Skip own mutations (already applied optimistically)
    // Add to appropriate list
    // Show toast for other users' actions
}
```

### 3.6 Subscription Flow

```
User opens Shopping List
    -> setupSubscriptions(householdId)
    -> Subscribe to onCreate/onUpdate/onDelete via WebSocket

Other user adds item
    -> WebSocket receives event
    -> Filter by householdId (client-side)
    -> Update activeItems/crossedOffItems
    -> Show toast: "Jane added Milk"

User joins new household
    -> Clear local data
    -> Unsubscribe from old household
    -> Load new household items
    -> Subscribe to new household
```

---

## Implementation Batches

### Batch 1: Auth Gate (Backend + iOS) - Agent 1

1. Add `name` index to Household schema in `resource.ts`
2. Deploy schema changes: `npx ampx sandbox`
3. Create `Views/RootView.swift`
4. Create `Views/Auth/AuthGateView.swift`
5. Create `Views/Auth/HouseholdSetupView.swift`
6. Update `GroceryAppApp.swift` to use `RootView`
7. Add `checkHouseholdNameAvailable()` to `AmplifyService.swift`
8. Simplify `SettingsView.swift` - remove auth forms
9. Simplify `HouseholdView.swift` - remove not-authenticated state

### Batch 2: Invite System Backend - Agent 2

1. Add `inviteCodeExpiresAt` to Household schema
2. Create `amplify/data/regenerateInviteCodeFunction/handler.ts`
3. Create `amplify/data/joinHouseholdFunction/handler.ts`
4. Create `amplify/data/sendInviteEmailFunction/handler.ts`
5. Update `amplify/backend.ts` with registrations and permissions
6. Add GraphQL mutations to `resource.ts`
7. Configure SES (manual AWS Console steps)
8. Deploy and test via AWS Console

### Batch 3: Invite System iOS - Agent 3 (after Batch 2)

1. Add invite methods to `AmplifyService.swift`:
   - `fetchHouseholdDetails()`
   - `regenerateInviteCode()`
   - `sendInviteEmail(to:)`
   - `joinHouseholdWithWarning(inviteCode:)`
2. Create `Views/HouseholdInviteView.swift`
3. Update `HouseholdView.swift`:
   - Add "Invite Members" button
   - Add join warning confirmation alert
   - Add "Leave Household" option

### Batch 4: Real-Time Subscriptions - Agent 4

1. Create `Services/SubscriptionService.swift`
2. Update `ShoppingListViewModel.swift`:
   - Add `setupSubscriptions()` and `teardownSubscriptions()`
   - Add Combine observation of SubscriptionService
   - Add `handleItemCreated/Updated/Deleted` handlers
3. Update `ShoppingListView.swift`:
   - Call setup on `.task`
   - Call teardown on `.onDisappear`
4. Update `AmplifyService.swift`:
   - Add `Notification.Name.householdChanged`
   - Post notification when household changes

---

## Critical Files Reference

### Backend
| File | Purpose |
|------|---------|
| `amplify/data/resource.ts` | Schema and mutation definitions |
| `amplify/backend.ts` | Lambda registrations and permissions |
| `amplify/data/regenerateInviteCodeFunction/handler.ts` | Generate new invite code |
| `amplify/data/joinHouseholdFunction/handler.ts` | Handle household switching |
| `amplify/data/sendInviteEmailFunction/handler.ts` | Send invite email via SES |

### iOS
| File | Purpose |
|------|---------|
| `GroceryApp/GroceryAppApp.swift` | App entry point |
| `GroceryApp/Views/RootView.swift` | State-based view router |
| `GroceryApp/Views/Auth/AuthGateView.swift` | Login/signup UI |
| `GroceryApp/Views/Auth/HouseholdSetupView.swift` | Household naming UI |
| `GroceryApp/Services/AmplifyService.swift` | All GraphQL methods |
| `GroceryApp/Services/SubscriptionService.swift` | WebSocket subscription manager |
| `GroceryApp/ViewModels/ShoppingListViewModel.swift` | Subscription event handlers |
| `GroceryApp/Views/HouseholdView.swift` | Invite button and UI |
| `GroceryApp/Views/HouseholdInviteView.swift` | Invite sheet with code/email |

---

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Existing user with no household | RootView shows HouseholdSetupView |
| Household name already taken | Show error, prompt for different name |
| Invite code expired | Show error, suggest requesting new code from household member |
| User was only member of household | Household becomes orphaned (cleanup via cron later) |
| Network disconnect during subscription | Reconnect and resubscribe on network restore |
| App backgrounded | Subscriptions remain active |
| User signs out | Clear all local state, teardown subscriptions |

---

## Testing Checklist

- [ ] Fresh signup flow: email -> verify -> name household -> main app
- [ ] Existing user login: straight to main app (has household)
- [ ] Existing user login: to household setup (no household)
- [ ] Household name uniqueness validation
- [ ] Invite code copy to clipboard
- [ ] Invite code share sheet
- [ ] Invite email sending
- [ ] Invite code expiration (wait 24h or mock)
- [ ] Invite code regeneration
- [ ] Join household with valid code
- [ ] Join household with expired code (error)
- [ ] Leave household warning
- [ ] Real-time item creation sync
- [ ] Real-time item update sync (check off/restore)
- [ ] Real-time item deletion sync
- [ ] Toast notifications for other users' actions
