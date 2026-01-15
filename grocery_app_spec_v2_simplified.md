# Grocery Shopping App - Revised Specification v2.0

**Version:** 2.0 (Simplified)  
**Date:** January 2026  
**Platform:** iOS Only  
**Purpose:** Personal Use  

---

## 1. CORE CONCEPT

A **dead-simple** collaborative grocery shopping app with git-style sync, two-tier list management, and intelligent store-mode sorting.

### Key Principles
- **Simple list management** - One shared list, real-time sync, no complexity
- **Git-style commits** - All changes are commits with author attribution
- **Two-tier architecture** - Community base list + user custom items
- **Smart modes** - Normal mode vs "At The Store" mode with aisle sorting
- **No duplicates** - Strict deduplication
- **Ephemeral notifications** - See what others are doing in real-time

---

## 2. LIST ARCHITECTURE

### 2.1 Two-Tier System

**Tier 1: Community Base Product List**
- Large catalog of known products (~50k-100k items)
- Synced from server, cached locally
- Read-only for users
- Includes:
  - Product name (normalized)
  - Common aliases
  - Default category/aisle mappings per store
  - Barcode (future phase)
  
**Tier 2: User Custom Items**
- Manually added items not in community list
- Household-specific
- Merged with community list for display
- **Always sorted to top** (high priority)

### 2.2 Display List (Merged View)
```
[CUSTOM ITEMS - User Added]
- Organic almond butter (added by John)
- That weird cheese from Whole Foods (added by Sarah)

[COMMUNITY ITEMS - From Base List]
- Milk
- Eggs  
- Bread
- ...
```

### 2.3 List States

**Active Shopping List**
- Items to buy (unchecked)
- Sorted: Custom items on top, then alphabetical (or by category)

**Crossed-Off List**
- Recently purchased items
- **Highest priority for re-adding** - one tap to restore
- Auto-archive after 30 days (configurable)

**"At The Store" Mode**
- Same items, different sorting
- Grouped by categories/aisles
- Follows physical store layout for efficient shopping
- Example grouping:
  ```
  Produce
    - Bananas
    - Lettuce
  
  Dairy (Aisle 3)
    - Milk
    - Yogurt
  
  Frozen (Aisle 20-21)
    - Ice cream
    - Frozen pizza
  ```

---

## 3. GIT-STYLE SYNC MODEL

### 3.1 Commit-Based Changes

Every action is a "commit":
```json
{
  "commitId": "uuid",
  "timestamp": "2026-01-04T10:30:00Z",
  "author": "John",
  "householdId": "abc123",
  "action": "ADD_ITEM",
  "payload": {
    "itemId": "uuid",
    "itemName": "Milk",
    "quantity": "1 gallon",
    "isCustom": false,
    "productId": "prod_12345"
  }
}
```

**Action Types:**
- `ADD_ITEM` - Add item to shopping list
- `REMOVE_ITEM` - Move item to crossed-off list
- `CHECK_OFF_ITEM` - Same as remove (mark purchased)
- `RESTORE_ITEM` - Re-add from crossed-off list
- `LOCK_ITEM` - Prevent others from removing
- `UNLOCK_ITEM` - Release lock
- `UPDATE_ITEM` - Edit quantity/notes

### 3.2 Real-Time Propagation

**Flow:**
1. User action → Create commit locally
2. Apply commit to local state immediately (optimistic UI)
3. Send commit to server via WebSocket
4. Server validates, assigns sequence number
5. Server broadcasts to all household clients
6. Clients receive commit, apply to local state
7. UI updates with ephemeral notification

**Conflict Resolution:**
- Commits have sequence numbers (server-assigned)
- Same item modified? → Last timestamp wins
- Duplicate item add? → Deduplicate (merge quantities/notes)
- Item locked? → Reject remove attempts

### 3.3 Offline Mode
- Queue commits locally
- When reconnected, replay queue
- Server resolves conflicts
- Client receives delta updates

### 3.4 No Duplicate Enforcement

**Deduplication Logic:**
- Normalize item names (lowercase, trim, remove punctuation)
- Check both tiers: custom items + community list
- If duplicate detected:
  - Update existing item (merge quantity if needed)
  - Show notification: "Milk already on list (added by Sarah)"

---

## 4. USER FLOWS

### 4.1 Adding Items

**Option 1: Search Community List**
1. Tap "+" or search bar
2. Type "mil" → Autocomplete shows:
   - Milk (community)
   - Milk - Oat (community)
   - Milk - Almond (community)
3. Tap item → Added to shopping list
4. Commit created, synced to household

**Option 2: AI Text/Voice Input**
1. User types or speaks: "add milk and eggs to the list"
2. AI parses:
   - "milk" → Match community item
   - "eggs" → Match community item
3. Both added as separate commits
4. Notifications to other users

**Option 3: Manual Custom Item**
1. Type item name not in community list: "Trader Joe's Everything Bagel Seasoning"
2. No match found → Create as custom item
3. Custom item stored in Tier 2
4. Always appears at top of list

### 4.2 Shopping ("At The Store" Mode)

1. User taps "At The Store" button
2. Select active store (e.g., "Stop & Shop Stamford")
3. List re-sorts by aisle order:
   ```
   Produce
   ☐ Bananas
   ☐ Lettuce
   
   Aisle 3 - Dairy
   ☐ Milk
   ☐ Yogurt
   
   Aisle 7 - Breakfast
   ☐ Cereal
   
   [Custom Items - Location Unknown]
   ☐ That weird cheese from Whole Foods
   ```
4. User walks through store, checks off items
5. Items move to "Crossed-Off" list in real-time
6. Other household members see updates live

### 4.3 Re-adding from Crossed-Off List

1. User goes to "Crossed-Off" tab (or it's inline collapsed section)
2. Recently purchased items shown with **highest priority**
3. Tap item → Immediately restored to active shopping list
4. Or swipe gesture for quick re-add
5. Commit created: `RESTORE_ITEM`

### 4.4 Item Locking

**Why Lock?**
- Prevent accidental removal of critical items
- Example: "Don't forget the birthday cake ingredients!"

**Flow:**
1. Long-press item → Lock option
2. Item shows lock icon 🔒
3. Other users see locked item
4. Attempt to remove → "Item locked by John"
5. Only John (or lock owner) can unlock/remove

---

## 5. DATA MODELS (SIMPLIFIED)

### 5.1 User
```json
{
  "userId": "uuid",
  "displayName": "John", 
  "avatarUrl": "https://...",
  "householdId": "uuid",
  "socialProvider": "apple|google"
}
```

### 5.2 Household
```json
{
  "householdId": "uuid",
  "members": ["userId1", "userId2"],
  "activeStoreId": "uuid (optional)"
}
```

### 5.3 Community Product (Tier 1)
```json
{
  "productId": "uuid",
  "name": "Milk",
  "normalizedName": "milk",
  "aliases": ["whole milk", "2% milk"],
  "defaultCategory": "Dairy",
  "storeAisleMappings": {
    "store_stopandshop_stamford": "Dairy",
    "store_wholefoods_chelsea": "3"
  }
}
```

### 5.4 Shopping List Item
```json
{
  "itemId": "uuid",
  "householdId": "uuid",
  "name": "Milk",
  "quantity": "1 gallon (optional)",
  "notes": "Get organic (optional)",
  "isCustom": false,
  "productId": "uuid (null if custom)",
  "status": "ACTIVE | CROSSED_OFF",
  "lockedBy": "userId (optional)",
  "addedBy": "userId",
  "addedAt": "timestamp",
  "crossedOffBy": "userId (optional)",
  "crossedOffAt": "timestamp (optional)",
  "version": "integer"
}
```

### 5.5 Commit Log
```json
{
  "commitId": "uuid",
  "sequenceNumber": "integer (server-assigned)",
  "householdId": "uuid",
  "author": "userId",
  "timestamp": "timestamp",
  "action": "ADD_ITEM | REMOVE_ITEM | CHECK_OFF_ITEM | ...",
  "payload": "json (action-specific)"
}
```

### 5.6 Store Profile
```json
{
  "storeId": "uuid",
  "name": "Stop & Shop Stamford",
  "aisles": [
    {
      "aisleNumber": "3",
      "name": "Dairy",
      "displayOrder": 10,
      "categories": ["Dairy", "Eggs", "Butter"]
    },
    {
      "aisleNumber": "Produce",
      "name": "Produce",
      "displayOrder": 1,
      "categories": ["Fruits", "Vegetables"]
    }
  ]
}
```

---

## 6. UI/UX

### 6.1 Main List Screen (Normal Mode)

```
┌─────────────────────────────────────┐
│  🏠 Shopping List          [At Store]│
│  ┌───────────────────────────────┐  │
│  │ Search or add item...     🎤   │  │
│  └───────────────────────────────┘  │
│                                      │
│  ━━━ CUSTOM ITEMS ━━━                │
│  ☐ Organic almond butter             │
│     Added by John • 2h ago           │
│                                      │
│  ━━━ SHOPPING LIST ━━━               │
│  ☐ Milk                              │
│  ☐ Eggs                              │
│  ☐ Bread                             │
│  ☐ Coffee 🔒                         │
│     Locked by Sarah                  │
│                                      │
│  ━━━ CROSSED OFF (12) ━━━ [Expand]   │
│                                      │
│  [+] Add Item                        │
└─────────────────────────────────────┘
```

### 6.2 "At The Store" Mode

```
┌─────────────────────────────────────┐
│  Stop & Shop Stamford    [Exit Store]│
│                                      │
│  ━━━ Produce ━━━                     │
│  ☐ Bananas                           │
│  ☐ Lettuce                           │
│                                      │
│  ━━━ Aisle 3 - Dairy ━━━             │
│  ☐ Milk                              │
│  ☑ Yogurt  (checked by Sarah)        │
│                                      │
│  ━━━ Aisle 7 - Breakfast ━━━         │
│  ☐ Cereal                            │
│                                      │
│  ━━━ Custom Items ━━━                │
│  ☐ Organic almond butter             │
│                                      │
│  Progress: 1/6 items                 │
└─────────────────────────────────────┘
```

### 6.3 Ephemeral Notifications

**Toast/Banner style:**
- "John added Milk"
- "Sarah checked off Yogurt"
- "Mike locked Coffee"
- Appears briefly (3s), doesn't interrupt

**Real-time indicators:**
- Avatar badge on items: "Sarah is viewing this"
- Typing indicator: "John is adding items..."

### 6.4 Crossed-Off List

**Inline collapsed section:**
```
━━━ CROSSED OFF (12) ━━━ [Expand]
[Tap to expand]

[Expanded:]
━━━ CROSSED OFF ━━━
Yogurt    [+] Re-add    (15 min ago)
Apples    [+] Re-add    (2h ago)
Chicken   [+] Re-add    (Yesterday)
...
```

**Or dedicated tab:**
- Recent (Today)
- This Week
- Older

---

## 7. SYNC ALGORITHM (SIMPLIFIED)

### 7.1 WebSocket Real-Time Sync

**Client → Server:**
1. User action creates commit
2. Apply locally (optimistic)
3. Send commit via WebSocket: `{ type: 'COMMIT', payload: commit }`

**Server Processing:**
1. Validate commit (household membership, no duplicates, locks)
2. Assign sequence number
3. Persist to database
4. Broadcast to all household clients: `{ type: 'NEW_COMMIT', payload: commit }`

**Server → Client:**
1. Receive commit from WebSocket
2. Check sequence number (already applied?)
3. Apply commit to local state
4. Update UI
5. Show ephemeral notification

### 7.2 Deduplication Check

**Server-side:**
```python
def validate_add_item(commit, household):
    item_name = normalize(commit.payload.itemName)
    
    # Check active list
    for item in household.active_items:
        if normalize(item.name) == item_name:
            return {
                "error": "DUPLICATE",
                "message": f"Item already on list (added by {item.addedBy})"
            }
    
    # Check community list (if not custom)
    if not commit.payload.isCustom:
        product = find_product(item_name)
        if product:
            # Use canonical product name
            commit.payload.name = product.name
            commit.payload.productId = product.id
    
    return {"ok": True}
```

### 7.3 Lock Enforcement

**Server-side:**
```python
def validate_remove_item(commit, household):
    item = household.find_item(commit.payload.itemId)
    
    if item.lockedBy and item.lockedBy != commit.author:
        return {
            "error": "LOCKED",
            "message": f"Item locked by {item.lockedBy}"
        }
    
    return {"ok": True}
```

### 7.4 Offline Queue Replay

**On Reconnect:**
1. Client sends: `{ type: 'SYNC', lastSeqNum: 42 }`
2. Server responds with commits 43-100
3. Client applies missing commits in order
4. Client replays queued local commits
5. Server validates each, may reject duplicates

---

## 8. AI-ASSISTED INPUT

### 8.1 Text Input with NLP

**User types:** "add milk, eggs, and bread"

**Processing:**
1. Parse natural language → Extract items
2. For each item:
   - Search community product list
   - Fuzzy match (Levenshtein distance)
   - If match > 90% confidence → Use community product
   - Else → Create custom item
3. Create commits for each item
4. Deduplicate before sending

**Libraries:**
- On-device NLP (Core ML / Natural Language framework)
- Or server-side (simple regex + fuzzy matching)

### 8.2 Voice Input (Siri Shortcuts)

**User says:** "Hey Siri, add milk to my grocery list"

**Flow:**
1. Siri invokes app intent
2. App receives: `{ action: 'addItem', item: 'milk' }`
3. Same processing as text input
4. Commit created, synced
5. Siri confirms: "I added milk to your grocery list"

### 8.3 Advanced AI (Future Phase)

- Image recognition: Take photo of product → Add to list
- Receipt parsing: Photo of receipt → Auto-add items
- Voice conversation: "What do I need for spaghetti?" → Add ingredients

---

## 9. TECHNICAL STACK (UPDATED)

### 9.1 Backend (AWS)

**Core Services:**
- **AWS Lambda** - Serverless functions for business logic
- **DynamoDB** - NoSQL database (households, items, commits)
- **API Gateway + WebSocket** - Real-time bidirectional sync
- **Cognito** - Social login (Apple, Google) for user IDs only
- **S3** - Store community product list (JSON, synced to clients)
- **CloudFront** - CDN for product list distribution

**Why WebSocket over AppSync?**
- Simpler for commit-based sync
- Lower latency
- More control over message format

### 9.2 Frontend (iOS)

**Core:**
- SwiftUI (UI)
- Combine (reactive state management)
- Core Data (local cache: items, commits, products)
- URLSession + Starscream (WebSocket library)

**State Management:**
- Single source of truth: `ShoppingListStore` (ObservableObject)
- Receives commits → Updates state → UI refreshes

**Persistence:**
- Core Data for offline storage
- Background sync on app resume

---

## 10. IMPLEMENTATION PHASES

### Phase 1: Core List (Week 1-3)
- Basic UI (list view, add item)
- Local state management
- Social login (Cognito)
- Household creation/joining

### Phase 2: Git Sync (Week 4-6)
- Commit model
- WebSocket connection to AWS
- Real-time sync
- Conflict resolution
- Offline queue

### Phase 3: Two-Tier System (Week 7-8)
- Community product list (mock dataset)
- Custom items (Tier 2)
- Merged display
- Deduplication logic

### Phase 4: "At The Store" Mode (Week 9-10)
- Store profiles
- Aisle data (Stop & Shop from your images)
- Re-sort by aisle
- Category grouping

### Phase 5: Polish (Week 11-12)
- Item locking
- Crossed-off list with re-add
- Ephemeral notifications
- Siri shortcuts
- UI refinements

**Total: 12 weeks**

---

## 11. OPEN QUESTIONS

1. **Community product list source?**
   - Build manually (start with ~1000 common items)
   - Scrape from grocery APIs
   - User-contributed (wiki model)

2. **Custom items promotion?**
   - If multiple households add same custom item → Promote to community?
   - Threshold: 10+ households?

3. **Crossed-off auto-archive?**
   - 30 days? 90 days? User configurable?

4. **Lock timeout?**
   - Locks expire after 24h? Or permanent until unlocked?

5. **WebSocket scaling?**
   - How many concurrent connections per household?
   - Use AWS API Gateway WebSocket (10k connections per endpoint)

6. **Product list update frequency?**
   - Weekly sync? Monthly?
   - Incremental updates or full replacement?

7. **Privacy?**
   - Should household members see who added what?
   - Option to add items anonymously?

---

## 12. SUCCESS CRITERIA

**MVP (Phase 1-5):**
- ✅ Real-time sync <1s latency
- ✅ Offline mode works, syncs on reconnect
- ✅ No duplicates allowed (enforced)
- ✅ "At The Store" mode resorts correctly
- ✅ Item locking prevents accidental removal
- ✅ 5+ household members can collaborate smoothly
- ✅ Community product list has 1000+ items
- ✅ Siri shortcuts work reliably

**User Experience:**
- Adding item: <2 seconds
- Checking off item: Instant
- Switching to store mode: <1 second
- UI feels fast and responsive

---

**End of Revised Specification v2.0**

This spec emphasizes **simplicity, git-style sync, and two-tier list management** per your feedback.
