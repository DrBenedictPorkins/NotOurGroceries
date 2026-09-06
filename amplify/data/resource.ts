import { type ClientSchema, a, defineData, defineFunction } from '@aws-amplify/backend';

// Import Lambda handlers defined in their own resource files (with secrets)
import { inferProductAisleFunction } from './inferProductAisleFunction/resource';
import { parseIngredientsFunction } from './parseIngredientsFunction/resource';
import { transcribeAudioFunction } from './transcribeAudioFunction/resource';

// Re-export for backend.ts
export { inferProductAisleFunction, parseIngredientsFunction, transcribeAudioFunction };

// ========================================
// LAMBDA FUNCTIONS
// ========================================

// DynamoDB Stream handler for creating Commit records
export const commitStreamHandler = defineFunction({
  name: 'commitStreamHandler',
  entry: './commitStreamHandler/handler.ts',
  resourceGroupName: 'data',
});

// Search products with fuzzy matching
export const itemImageFunction = defineFunction({
  name: 'itemImageFunction',
  entry: './itemImageFunction/handler.ts',
  timeoutSeconds: 30,
});

export const searchProductsFunction = defineFunction({
  name: 'searchProductsFunction',
  entry: './searchProductsFunction/handler.ts',
  resourceGroupName: 'data',
});

// Regenerate invite code for a household
export const regenerateInviteCodeFunction = defineFunction({
  name: 'regenerateInviteCodeFunction',
  entry: './regenerateInviteCodeFunction/handler.ts',
  resourceGroupName: 'data',
});

// Join a household with invite code
export const householdMembershipFunction = defineFunction({
  name: 'householdMembershipFunction',
  entry: './householdMembershipFunction/handler.ts',
  // Same stack as the data it reads. Every other function here does this, and
  // omitting it is what broke two deploys: the function ends up in its own
  // stack, the data stack depends on it as a mutation handler, it depends on
  // the data stack for table names, and CloudFormation refuses the cycle.
  resourceGroupName: 'data',
  timeoutSeconds: 60,
});

export const joinHouseholdFunction = defineFunction({
  name: 'joinHouseholdFunction',
  entry: './joinHouseholdFunction/handler.ts',
  resourceGroupName: 'data',
});

// Everything the app needs to be usable, in one call. See the handler.
export const handshakeFunction = defineFunction({
  name: 'handshakeFunction',
  entry: './handshakeFunction/handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 30,
});

// One account, one device: claim it on sign-in, verify it on every launch.
export const claimDeviceFunction = defineFunction({
  name: 'claimDeviceFunction',
  entry: './claimDeviceFunction/handler.ts',
  resourceGroupName: 'data',
});

// Redeem a comp code: burn it, then lift the household's allowances.
export const redeemCompCodeFunction = defineFunction({
  name: 'redeemCompCodeFunction',
  entry: './redeemCompCodeFunction/handler.ts',
  resourceGroupName: 'data',
});

// End a shopping trip in one call instead of one per item.
export const finishShoppingFunction = defineFunction({
  name: 'finishShoppingFunction',
  entry: './finishShoppingFunction/handler.ts',
  resourceGroupName: 'data',
  // A full list is capped at 150 items and each one is a conditional update.
  // Comfortably inside this; the default 3s is not.
  timeoutSeconds: 60,
});

// Where the caller's household stands against its allowances. Read-only; the
// counters are written by the Lambdas that do the metered work.
export const householdAllowancesFunction = defineFunction({
  name: 'householdAllowancesFunction',
  entry: './householdAllowancesFunction/handler.ts',
  resourceGroupName: 'data',
});

// Admin MCP function for database management
export const adminMcpFunction = defineFunction({
  name: 'adminMcpFunction',
  entry: './adminMcpFunction/handler.ts',
  resourceGroupName: 'data',
});


// ========================================
// SCHEMA DEFINITION
// ========================================
const schema = a.schema({
  // ========================================
  // ENUMS
  // ========================================
  ItemStatus: a.enum(['ACTIVE', 'IN_CART', 'SUGGESTION']),

  ShoppingStatus: a.enum(['IDLE', 'AT_STORE', 'AD_HOC']),

  /// What lifts a household's allowances. SUBSCRIBED is a validated receipt and
  /// lapses with `subscriptionExpiresAt`; COMPED is set by hand from the admin
  /// tooling and never lapses. See MONETIZATION.qmd.
  Entitlement: a.enum(['FREE', 'SUBSCRIBED', 'COMPED']),

  CommitAction: a.enum([
    'ADD_ITEM',
    'REMOVE_ITEM',
    'MOVE_TO_CART',
    'RESTORE_TO_LIST',
    'MOVE_TO_SUGGESTIONS',
    'LOCK_ITEM',
    'UNLOCK_ITEM',
    'UPDATE_ITEM',
  ]),

  // Shopping request types (for request/approval inbox)
  RequestType: a.enum(['ADD_ITEM', 'REMOVE_ITEM']),
  RequestStatus: a.enum(['PENDING', 'APPROVED', 'REJECTED']),

  // Mapping source (how the product-aisle mapping was determined)
  // USER_SIGHTED beats both of the others: somebody stood in the aisle and read
  // the sign. Inference must never overwrite one.
  MappingSource: a.enum(['IMAGE', 'LLM_GUESS', 'USER_SIGHTED']),


  // ========================================
  // USER MODEL
  // ========================================
  User: a
    .model({
      email: a.string().required(),
      displayName: a.string().required(),
      avatarUrl: a.string(),
      /// Assigned on join, picked from the six-colour palette so that no two
      /// members of a household share one. It tints the `[name]` attribution on
      /// list rows, which is the only thing distinguishing who added what.
      profileColor: a.string(),
      householdId: a.id(),
      household: a.belongsTo('Household', 'householdId'),
      /// The one device this account is signed in on.
      ///
      /// Written only by `claimDeviceFunction` over IAM — the row is
      /// `allow.owner()`, so leaving it client-writable would let a superseded
      /// device simply reclaim itself. Newest sign-in wins; see that handler for
      /// why one device rather than many.
      activeDeviceId: a.string(),
      activeDeviceName: a.string(),
      activeDeviceClaimedAt: a.datetime(),
      /// The Cognito group that guards this row — the household's id repeated
      /// into a plain, non-key field.
      ///
      /// It cannot be `householdId` itself. That column is the partition key of
      /// the `householdId` GSI, and `groupDefinedIn` is compiled into a DynamoDB
      /// filter expression; DynamoDB rejects a filter on a key attribute. A
      /// top-level query survives it because AppSync folds the condition into the
      /// key condition, but the `Household.members` connection resolver adds it
      /// as a separate filter and the read fails with
      /// "Filter Expression can only contain non-primary key attributes".
      /// That took out the whole members list. Same reason `Household` carries
      /// `groupName` instead of using its own id.
      householdGroup: a.string(),
      lastActive: a.datetime(),
    })
    .authorization((allow) => [
      // Your own row, which has to be readable before you know your household —
      // it is where the householdId comes from.
      allow.owner(),
      // Everyone else in your household, so a shopper's name resolves. This
      // replaced `authenticated().to(['read'])`, under which every account in
      // the system could read every user's row.
      allow.groupDefinedIn('householdGroup').to(['read']),
    ])
    .secondaryIndexes((index) => [
      index('householdId'),
    ]),

  // ========================================
  // HOUSEHOLD MODEL
  // ========================================
  Household: a
    .model({
      name: a.string().required(),
      /// Whoever created it. The only power it carries is removing other
      /// members; there is no role system and nothing else checks it. Optional
      /// because households created before this existed have no owner, and a
      /// household without one simply cannot remove anybody.
      ownerId: a.id(),
      /// The Cognito group that guards this row, which is the household's own id
      /// repeated into an ordinary field.
      ///
      /// `groupDefinedIn('id')` reads correctly but breaks subscriptions —
      /// observed on device as "Household subscription fatal error" while the
      /// identical rule on GroceryItem's `householdId` connected fine. AppSync
      /// cannot build a subscription auth filter from the primary key. So the
      /// group name lives in a field like everywhere else.
      groupName: a.string(),
      inviteCode: a.string().required(),
      inviteCodeExpiresAt: a.datetime().required(),
      activeStoreId: a.id(), // Legacy - kept for backwards compatibility
      activeStore: a.belongsTo('Store', 'activeStoreId'), // Legacy
      members: a.hasMany('User', 'householdId'),
      groceryItems: a.hasMany('GroceryItem', 'householdId'),
      commits: a.hasMany('Commit', 'householdId'),
      stores: a.hasMany('HouseholdStore', 'householdId'),
      shoppingRequests: a.hasMany('ShoppingRequest', 'householdId'),
      sequenceNumber: a.integer().default(0),
      // Shopping mode status
      shoppingStatus: a.ref('ShoppingStatus'),  // IDLE, AT_STORE, or AD_HOC (store-less errand)
      activeShopperId: a.id(),  // User ID of the person currently shopping
      shoppingStoreId: a.id(),  // HouseholdStore ID where they're shopping
      shoppingStartedAt: a.datetime(),  // When the current session began — drives abandoned-session detection on other members' devices
      // The last trip `finishShopping` put away. Its only job is to recognise
      // the same finish arriving twice — the call is queued and retried when a
      // trip ends with no signal, and a lost reply is indistinguishable from a
      // failure to the phone that sent it.
      lastFinishedTripId: a.string(),
    })
    .authorization((allow) => [
      // Creation cannot go through this rule — nobody is in the group before the
      // household exists — which is why householdMembership creates it with IAM.
      allow.groupDefinedIn('groupName'),
    ])
    .secondaryIndexes((index) => [
      index('inviteCode'),
      index('name').queryField('listHouseholdByName'),
    ]),

  // ========================================
  // HOUSEHOLD ALLOWANCE (metering and entitlement)
  // ========================================
  /// One row per household, `id` equal to the household id. Kept off `Household`
  /// on purpose: members can update their own household row from the client,
  /// and a counter or an entitlement flag a member can write is not a limit.
  /// This row is readable by the household and written only by Lambdas over
  /// IAM — `amplify/data/allowance.ts` is the sole writer.
  HouseholdAllowance: a
    .model({
      groupName: a.string().required(),
      entitlement: a.ref('Entitlement').required(),
      subscriptionExpiresAt: a.datetime(),
      /// Start of the first period. The current period is derived from it in
      /// thirty-day steps; the counters are zeroed lazily on the first read
      /// after a boundary.
      periodStartedAt: a.datetime().required(),
      placementsThisPeriod: a.integer().default(0),
      parsesThisPeriod: a.integer().default(0),
    })
    .authorization((allow) => [
      allow.groupDefinedIn('groupName').to(['read']),
    ]),

  // One row per minted comp code. The cap on comped households *is* the number
  // of rows: mint a hundred and a hundred-and-first cannot be redeemed, because
  // there is nothing to redeem. No counter, so no race.
  //
  // Nobody can read this through the API. `admins` is a Cognito group with no
  // members and never will have any — it exists to make the deny explicit,
  // because a model readable by authenticated users is a model where anybody
  // lists all hundred codes and spends them. The Lambda reaches the table
  // directly over IAM, exactly as `allowance.ts` does.
  CompCode: a
    .model({
      code: a.string().required(),
      redeemedByHouseholdId: a.id(),
      redeemedAt: a.datetime(),
      /// Free text for whoever minted it — which batch, who it went to.
      note: a.string(),
    })
    .identifier(['code'])
    .authorization((allow) => [
      allow.group('admins'),
    ]),

  // ========================================
  // GROCERY ITEM MODEL (Shopping List Item)
  // ========================================
  GroceryItem: a
    .model({
      householdId: a.id().required(),
      household: a.belongsTo('Household', 'householdId'),
      name: a.string().required(),
      normalizedName: a.string().required(),
      quantity: a.string(),
      notes: a.string(),
      // When true, `notes` is trip-scoped ("get only 1", "optional if found")
      // and is wiped when the shopping session that used it finishes.
      notesEphemeral: a.boolean().default(false),
      // Item belongs to the current store-less ad-hoc trip, not the main list.
      adHoc: a.boolean().default(false),
      // Ad-hoc item that was pulled off the main list rather than typed fresh.
      // Decides its fate if the trip ends without it being bought: pulled items
      // return to the main list, fresh ones are discarded.
      adHocPulled: a.boolean().default(false),
      isCustom: a.boolean().required().default(false),
      productId: a.id(),
      product: a.belongsTo('Product', 'productId'),
      status: a.ref('ItemStatus').required(),
      lockedBy: a.id(),
      addedBy: a.id().required(),
      addedAt: a.datetime().required(),
      // DEPRECATED — the client no longer reads or writes this. Kept only so builds
      // <= v1.3.0, which still select `reactions`, keep passing AppSync validation.
      // Drop it once App Store Connect shows every tester on the newer build.
      reactions: a.json(),
      images: a.json(),
      version: a.integer().required().default(0),
    })
    .authorization((allow) => [
      allow.groupDefinedIn('householdId'),
    ])
    .secondaryIndexes((index) => [
      index('householdId').sortKeys(['status']).queryField('listItemsByHouseholdAndStatus'),
      // Temporarily commented out - causing empty string issue with normalizedName
      // index('householdId').sortKeys(['normalizedName']).queryField('listItemsByHouseholdAndName'),
    ]),

  // ========================================
  // PRODUCT MODEL (Community Products - Tier 1)
  // ========================================
  Product: a
    .model({
      name: a.string().required(),
      normalizedName: a.string().required(),
      aliases: a.string().array(),
      category: a.string().required(),
      storeAisleMappings: a.json(),
      groceryItems: a.hasMany('GroceryItem', 'productId'),
    })
    .authorization((allow) => [
      allow.authenticated().to(['read']),
      allow.group('admin'),
    ])
    .secondaryIndexes((index) => [
      index('normalizedName').queryField('productsByNormalizedName'),
      index('category').queryField('productsByCategory'),
    ]),

  // ========================================
  // STORE MODEL
  // ========================================
  Store: a
    .model({
      name: a.string().required(),
      chain: a.string().required(),
      address: a.string().required(),
      city: a.string().required(),
      state: a.string().required(),
      zip: a.string().required(),
      latitude: a.float(),
      longitude: a.float(),
      aisles: a.hasMany('Aisle', 'storeId'),
      verified: a.boolean().default(false),
      households: a.hasMany('Household', 'activeStoreId'),
    })
    .authorization((allow) => [
      allow.authenticated().to(['read']),
      allow.group('admin'),
    ]),

  // ========================================
  // AISLE MODEL (Legacy - for verified stores)
  // ========================================
  Aisle: a
    .model({
      storeId: a.id().required(),
      store: a.belongsTo('Store', 'storeId'),
      number: a.string().required(),
      name: a.string().required(),
      displayOrder: a.integer().required(),
      categories: a.string().array().required(),
    })
    .authorization((allow) => [
      allow.authenticated().to(['read']),
      allow.group('admin'),
    ])
    .secondaryIndexes((index) => [
      index('storeId').sortKeys(['displayOrder']).queryField('aislesByStoreOrdered'),
    ]),

  // ========================================
  // HOUSEHOLD STORE MODEL (User-owned stores)
  // ========================================
  HouseholdStore: a
    .model({
      householdId: a.id().required(),
      household: a.belongsTo('Household', 'householdId'),
      name: a.string().required(),
      chain: a.string(),
      address: a.string(),
      aisleLayout: a.json(), // [{id, number, name, displayOrder}]
      productMappings: a.hasMany('ProductAisleMapping', 'storeId'),
    })
    .authorization((allow) => [allow.groupDefinedIn('householdId')])
    .secondaryIndexes((index) => [
      index('householdId').queryField('storesByHousehold'),
    ]),

  // ========================================
  // PRODUCT AISLE MAPPING MODEL
  // ========================================
  ProductAisleMapping: a
    .model({
      /// Denormalised from the store so this row can be authorized on its own.
      /// Dynamic group auth reads a field on the record itself; it cannot follow
      /// `storeId` to HouseholdStore to find out whose it is. Optional so rows
      /// written before this decode, and backfilled for the ones that exist.
      householdId: a.id(),
      storeId: a.id().required(),
      store: a.belongsTo('HouseholdStore', 'storeId'),
      productId: a.id(),
      normalizedName: a.string(),
      // LLM/Image suggestion (always preserved, never overwritten by user)
      aisleId: a.string().required(),            // LLM's suggested aisle
      confidence: a.float(),                      // 0.0 - 1.0 (e.g., 0.93 = 93%)
      source: a.ref('MappingSource'),            // How LLM determined it
      // User override (takes precedence when present)
      userAisleOverride: a.string(),             // null = use LLM suggestion
      // Audit/Logging (answer "why is X in aisle Y?")
      reasoning: a.string(),                     // LLM's explanation for assignment
      sourceImageKeys: a.string().array(),       // Which S3 images contributed
      mappedAt: a.datetime(),                    // When LLM made this assignment
    })
    .authorization((allow) => [allow.groupDefinedIn('householdId')])
    .secondaryIndexes((index) => [
      index('storeId').queryField('mappingsByStore'),
      index('productId').queryField('mappingsByProduct'),
    ]),

  // ========================================
  // COMMIT MODEL (Git-style history)
  // ========================================
  Commit: a
    .model({
      householdId: a.id().required(),
      household: a.belongsTo('Household', 'householdId'),
      sequenceNumber: a.integer().required(),
      author: a.id().required(),
      authorName: a.string().required(),
      action: a.ref('CommitAction').required(),
      payload: a.json().required(),
    })
    .authorization((allow) => [
      allow.groupDefinedIn('householdId'),
    ])
    .secondaryIndexes((index) => [
      index('householdId').sortKeys(['sequenceNumber']).queryField('commitsByHouseholdSequence'),
    ]),

  // ========================================
  // SHOPPING REQUEST MODEL (Request/Approval Inbox)
  // ========================================
  // DEPRECATED — the request/approve inbox was removed from the client. In seven
  // months it was never used once: the ShoppingRequest table has zero rows, ever.
  // The premise was wrong too. An in-app request has no delivery guarantee, so
  // anything genuinely urgent gets re-sent by text anyway, and an inbox invites
  // the pile-on failure other apps get complained about.
  //
  // The model stays only so builds that still subscribe to onCreateShoppingRequest
  // keep passing AppSync validation. Drop it, and RequestType, once every tester
  // is past v1.6.0. Same gate as `reactions`.
  ShoppingRequest: a
    .model({
      householdId: a.id().required(),
      household: a.belongsTo('Household', 'householdId'),

      // Request details
      requestType: a.ref('RequestType').required(),  // ADD_ITEM or REMOVE_ITEM
      itemName: a.string().required(),               // Display name
      normalizedName: a.string(),                    // For ADD requests
      quantity: a.string(),                          // Optional quantity
      notes: a.string(),                             // Optional notes
      productId: a.id(),                             // For ADD requests (if from catalog)
      targetItemId: a.id(),                          // For REMOVE requests (existing item ID)

      // Requester info
      requestedBy: a.id().required(),                // User ID who made request
      requestedAt: a.datetime().required(),

      // Resolution
      status: a.ref('RequestStatus').required(),     // PENDING, APPROVED, REJECTED
      resolvedBy: a.id(),                            // Shopper who resolved
      resolvedAt: a.datetime(),
    })
    .authorization((allow) => [
      allow.groupDefinedIn('householdId'),
    ])
    .secondaryIndexes((index) => [
      index('householdId').sortKeys(['requestedAt']).queryField('requestsByHousehold'),
      index('householdId').sortKeys(['status']).queryField('requestsByHouseholdAndStatus'),
    ]),

  // ========================================
  // CUSTOM QUERIES
  // ========================================

  // Search products with fuzzy matching
  /// Signed access to an item photo, checked against the caller's household.
  ///
  /// The bucket grants the client nothing; every read, write and delete comes
  /// through here so the household id in the key can be compared with the
  /// caller's Cognito groups. See `itemImageFunction/handler.ts`.
  itemImage: a
    .mutation()
    .arguments({
      action: a.string().required(),
      s3Key: a.string(),
      itemId: a.string(),
      householdId: a.id(),
    })
    .returns(a.customType({
      url: a.string(),
      s3Key: a.string().required(),
      expiresIn: a.integer().required(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(itemImageFunction)),

  searchProducts: a
    .query()
    .arguments({
      query: a.string().required(),
      limit: a.integer(),
    })
    .returns(a.ref('Product').array())
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(searchProductsFunction)),

  /// Entitlement, usage this period, the caps and when the period rolls, for the
  /// caller's household. The caps come from here so the app never hardcodes one.
  householdAllowances: a
    .query()
    .returns(a.customType({
      // A string, not a.ref('Entitlement'): the enum ref in a custom return type
      // gives the handler an opaque type it cannot construct.
      entitlement: a.string().required(),
      entitled: a.boolean().required(),
      periodResetsAt: a.datetime().required(),
      placementsUsed: a.integer().required(),
      placementsCap: a.integer().required(),
      parsesUsed: a.integer().required(),
      parsesCap: a.integer().required(),
      membersCap: a.integer().required(),
      itemsCap: a.integer().required(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(householdAllowancesFunction)),

  // Regenerate invite code for a household
  regenerateInviteCode: a
    .mutation()
    .arguments({
      householdId: a.id().required(),
    })
    .returns(a.customType({
      inviteCode: a.string().required(),
      expiresAt: a.datetime().required(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(regenerateInviteCodeFunction)),

  // Join a household with invite code
  joinHousehold: a
    .mutation()
    .arguments({
      inviteCode: a.string().required(),
    })
    .returns(a.customType({
      householdId: a.id().required(),
      householdName: a.string().required(),
      previousHouseholdId: a.id(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(joinHouseholdFunction)),

  // Remove a member, or leave a household.
  //
  // Has to be a function: User is allow.owner(), so no client can clear another
  // member's householdId, and the owner check has to run somewhere the caller
  // cannot skip.
  manageHouseholdMembership: a
    .mutation()
    .arguments({
      action: a.string().required(),   // "create" | "remove" | "leave" | "deleteAccount"
      memberId: a.id(),                // required for "remove"
      name: a.string(),                // required for "create"
    })
    .returns(a.customType({
      householdId: a.id().required(),
      householdDeleted: a.boolean().required(),
      remainingMembers: a.integer().required(),
      inviteCode: a.string(),          // returned by "create"
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(householdMembershipFunction)),

  // One call that populates the whole app: profile, household, members, items,
  // stores, allowances, the product catalogue, and whether this device still
  // holds the account. Returns JSON because it is a bag of existing model
  // shapes, not a new type — repeating every field here would mean editing this
  // mutation every time any model gains one.
  handshake: a
    .query()
    .arguments({
      deviceId: a.string(),
    })
    .returns(a.json())
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(handshakeFunction)),

  // Claim this device for the account, or check we still hold it.
  claimDevice: a
    .mutation()
    .arguments({
      action: a.string().required(),   // "claim" | "verify"
      deviceId: a.string().required(),
      deviceName: a.string(),
    })
    .returns(a.customType({
      stillOurs: a.boolean().required(),
      /// What replaced us, for the message. Null while we still hold it.
      activeDeviceName: a.string(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(claimDeviceFunction)),

  // Type a code, get comped. The whole of the first-hundred onboarding.
  redeemCompCode: a
    .mutation()
    .arguments({
      code: a.string().required(),
    })
    .returns(a.customType({
      // COMPED | ALREADY_ENTITLED | SPENT | INVALID
      status: a.string().required(),
      message: a.string().required(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(redeemCompCodeFunction)),

  // Put a finished shopping trip away in one call.
  //
  // `toSuggestion` is the whole outcome the shopper's phone decided: what was
  // bought, plus what was left behind if they chose to discard it. The server is
  // not asked to work any of that out — see the handler for why this is a
  // statement and not a merge.
  finishShopping: a
    .mutation()
    .arguments({
      // Client-generated, so a retry of the same trip is recognisable.
      tripId: a.string().required(),
      householdId: a.id().required(),
      toSuggestion: a.string().array(),
      clearNotesFor: a.string().array(),
      // Items added during the trip while offline, whole, with the status the
      // client already decided. JSON because the shape is a GroceryItem.
      created: a.json(),
      // False when the trip was never announced — it started with no signal, so
      // there is no household status to put back.
      endTrip: a.boolean().required(),
    })
    .returns(a.customType({
      tripId: a.string().required(),
      alreadyApplied: a.boolean().required(),
      itemsUpdated: a.integer().required(),
      itemsCreated: a.integer().required(),
      notesCleared: a.integer().required(),
      householdEnded: a.boolean().required(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(finishShoppingFunction)),

  // Infer aisle for a single product using AI and existing store mappings
  inferProductAisle: a
    .mutation()
    .arguments({
      storeId: a.id().required(),
      productName: a.string().required(),
      normalizedName: a.string().required(),
      productId: a.id(),
    })
    .returns(a.customType({
      success: a.boolean().required(),
      suggestedAisle: a.string(),
      confidence: a.float(),
      reasoning: a.string(),
      error: a.string(),
    }))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(inferProductAisleFunction)),

  // Batch infer product aisles (uses same handler)
  inferProductAisleBatch: a
    .mutation()
    .arguments({
      storeId: a.id().required(),
      products: a.json().required(),  // Array of {productName, normalizedName, productId?}
    })
    .returns(a.json())  // Returns {success, results: [...]} or {success: false, error}
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(inferProductAisleFunction)),

  // Parse raw text (recipe, notes, list) into clean grocery items using AI
  parseIngredients: a
    .mutation()
    .arguments({
      rawText: a.string(),
      knownTerms: a.string().array(),
      imageData: a.string(),
    })
    .returns(a.json())
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(parseIngredientsFunction)),

  // Transcribe base64-encoded audio (m4a) via OpenAI Whisper, returns plain text
  transcribeAudio: a
    .mutation()
    .arguments({
      audioData: a.string().required(),
    })
    .returns(a.string())
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(transcribeAudioFunction)),

  // Upsert a ProductAisleMapping — unconditional write via custom resolver (no duplicate-key errors)
  upsertProductAisleMapping: a
    .mutation()
    .arguments({
      id: a.string().required(),
      // Required: the resolver both checks it against the caller's groups and
      // writes it, since it bypasses the model's own authorization.
      householdId: a.id().required(),
      storeId: a.id().required(),
      aisleId: a.string().required(),
      normalizedName: a.string(),
      productId: a.id(),
      confidence: a.float(),
      source: a.string(),
      reasoning: a.string(),
      mappedAt: a.datetime(),
      /// Set when a person told us where something is. `aisleId` stays whatever
      /// the model last guessed; this is what actually wins at read time.
      userAisleOverride: a.string(),
    })
    .returns(a.ref('ProductAisleMapping'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.custom({
      dataSource: a.ref('ProductAisleMapping'),
      entry: './upsertProductAisleMapping.js',
    })),
});

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    // Cognito user pools only. The API key auth mode was removed deliberately:
    // nothing used it (the app sets amazonCognitoUserPools on every request and
    // Lambdas talk to DynamoDB over IAM), and its 30-day expiry left CloudFormation
    // referencing a key AWS had already reaped, which blocked every subsequent
    // deploy with a 404 on AWS::AppSync::ApiKey.
    defaultAuthorizationMode: 'userPool',
  },
});
