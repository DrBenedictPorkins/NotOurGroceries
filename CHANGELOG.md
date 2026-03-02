# Changelog

All notable changes to NotOurGroceries will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/DrBenedictPorkins/NotOurGroceries/compare/v1.0-15...HEAD
[1.0]: https://github.com/DrBenedictPorkins/NotOurGroceries/releases/tag/v1.0-2[1.0.0]: https://github.com/DrBenedictPorkins/NotOurGroceries/releases/tag/v1.0.0
