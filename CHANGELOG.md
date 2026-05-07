# Changelog

All notable changes to NotOurGroceries will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.1] - 2026-05-06

## [1.1.1] - 2026-05-07

- Fix: bulk import now correctly parses ingredients (AppSync AWSJSON double-encoding resolved at source)
- Fix: debug builds now use the production backend
- Bulk import: parsed items are matched against the product catalog so aisle mapping works immediately
- Bulk import: catalog terms added to AI prompt for consistent item naming (e.g. "Carrot" not "Carrots")

## [1.1.0] - 2026-05-06

## [1.0] - 2026-04-29

Build 26


- Bulk import: paste a recipe, chat message, or any ingredient list — AI cleans it into individual grocery items, you review and select, then they're added to the list in one tap
- Fix: re-saving an AI-inferred aisle for an item no longer fails with a "duplicate key" error
- Fix: aisle scanner now correctly maps standard store sections (Produce, Dairy, Meat, etc.) to their standard IDs instead of raw text strings

## [1.0] - 2026-03-03

Build 25

- Phase 5 in aisle scan job: after each scan, custom household items (user-created, no catalog match) are now automatically assigned aisles via AI inference
- At-Store pre-check: when entering shopping mode, any new custom items with no aisle mapping get inferred on the fly before the list loads
- StoreAisle now carries a description field used as LLM context for standard sections (Produce, Dairy, Meat, etc.)

## [1.0] - 2026-03-02

Build 24


## [1.0] - 2026-03-03

Build 24

- Add standard store sections (Produce, Meat & Poultry, Seafood, Dairy & Eggs, Deli, Bakery, Frozen) to all new stores automatically
- Existing stores get standard sections added when opening aisle management

## [1.0] - 2026-03-02

Build 23


## [1.0] - 2026-03-03

Build 23

- Fix: Brief flash of "Set Up Household" screen after login — UI now waits for profile fetch to complete before transitioning, so it goes directly to the shopping list

## [1.0] - 2026-03-02

Build 22


## [1.0] - 2026-03-03

Build 22

- Fix: Remove stale API key from prod config — invalid api_key in amplify_outputs_prod.json caused Amplify SDK to register a broken auth interceptor, silently corrupting all GraphQL auth before requests left the device
- Add diagnostic logging to profile fetch for auth troubleshooting

## [1.0] - 2026-03-03

Build 21

- Fix: App showed "create/join household" after login — Amplify API plugin was silently falling back to API key auth after signOut+signIn, causing all GraphQL requests to fail the "authenticated user" check. All API calls now explicitly specify Cognito User Pool auth mode.

## [1.0] - 2026-03-03

Build 20

- Fix: After login, app showed "create/join household" instead of loading existing household — caused by a pre-signout call inside signIn() that corrupted the Amplify API plugin's auth state, causing all subsequent API calls to fall back to API key auth and fail with "Not Authorized"

## [1.0] - 2026-03-02

Build 19

- Fix: Sign-in loop — after logging in, app briefly showed household screen then returned to sign-in. Caused by overly aggressive auth error detection in profile fetch calling sign-out on any failure
- Fix: Aisle mappings showing 0 mapped items — invalid enum value `LLM_INFER` in database records caused AppSync to error on the entire mappings query; records updated and backend fixed

## [1.0] - 2026-03-02

Build 18

- Aisle scan now updates the aisle management view progressively as each phase completes, rather than waiting for the full job to finish

## [1.0] - 2026-03-02

Build 17

- Fix: Aisle scan images were not being resized before upload (UIImage.size returns points, not pixels — on a 3x device a 12MP photo appeared already small enough and was sent full-resolution, hitting Claude's 5MB limit)

## [1.0] - 2026-03-02

Build 16

- Fix: Scrolling blocked on some devices (iPhone 15) — removed conflicting gesture
- Household page now refreshes when foregrounded or pulled down
- Aisle scan: image pre-processing now matches Claude's recommended resolution (1568px)
- Aisle scan: items listed on store sign but not in catalog now get aisle mappings
- Aisle scan: catalog products not found on sign get AI-inferred aisles automatically
- Aisle re-scan now always refreshes mappings with latest data (manual overrides preserved)

## [1.0] - 2026-03-01

Build 15

- Tap suggestion items to move them to the active list (same as swipe-right)
- Undo button moved to sort strip (right-aligned) for consistency with At Store screen
- Undo strip stays visible even when active list is empty (so undo isn't lost)
- 1.5s interaction lock after app wakeup to prevent accidental taps

## [1.0] - 2026-03-01

Build 14

- Fix: At Store list not scrollable due to long press gesture blocking scroll

## [1.0] - 2026-03-01

Build 13

- Fix: Shopping list was not scrollable due to long press gesture blocking scroll

## [1.0] - 2026-03-01

Build 12

- Long press (0.5s) to move items on/off the shopping list (prevents accidental removals)
- 3-dot button on each row opens the item detail sheet
- New and restored items appear at the top of their list
- Swipe-to-delete button is now red
- Search bar focuses keyboard on tap anywhere (not just the magnifying glass icon)
- "Added by" shows who last put an item on the active list; hidden when item is not active
- Fix: Aisle scanning now uses current Claude model aliases (prevents API failures)
- Fix: Shopping list was empty on app restart due to stale field in GraphQL query

## [1.0] - 2026-02-18

Build 11

## [1.0] - 2026-02-18

Build 10

## [1.0] - 2026-02-06

Build 9

## [1.0] - 2026-02-06

Build 8

## [1.0] - 2026-02-01

Build 7

- Header cleanup: Username and version now on single line ("Mike • v1.0 (7)")
- Simplified sort bar: Combined A-Z/Z-A into single toggle button
- Removed non-functional scroll-to-top zone (^^^ chevrons)

## [1.0] - 2026-02-01

Build 6

- Added version/build number display to Stores view header
- Added foreground refresh to StoresView and StoreDetailView (data refreshes when app returns from background)

## [1.0] - 2026-02-01

Build 5

## [1.0] - 2026-02-01

Build 4

## [1.0] - 2026-02-01

Build 3

## [1.0] - 2026-02-01

Build 2

## [1.0.0] - 2026-01-18

Build 1

### Added

- User authentication with AWS Cognito (sign up, sign in, sign out, password recovery)
- Household creation and management with shareable invite codes
- Real-time shopping list sync across all household members via AWS AppSync
- Product catalog with 239 pre-seeded grocery items
- Item suggestions from previous shopping trips for quick list building
- Shopping mode (At Store) with item crossing off and cart tracking
- AI-powered aisle mapping with photo scanning capability
- Manual aisle assignment for products
- Multiple household stores support with per-store aisle configurations
- Debug/Production environment separation with automatic backend selection
- TestFlight distribution for beta testing

[Unreleased]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/compare/v1.1.1...HEAD
[1.1.1]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.1.1
[1.1.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.1.0
[1.0]: https://github.com/DrBenedictPorkins/NotOurGroceries/releases/tag/v1.0-2[1.0.0]: https://github.com/DrBenedictPorkins/NotOurGroceries/releases/tag/v1.0.0
