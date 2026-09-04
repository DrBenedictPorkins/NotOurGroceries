# Changelog

All notable changes to Got Dill will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Aisles
- **Say where something is, standing in front of it.** Open an item, hold the pill, say "aisle twelve" or "international" — it lands on that item and the shop remembers. Recognised on your phone, so it works deep inside a store with no signal
- Or tap it. The aisle numbers are on screen now; the ones this shop already knows are green. One tap saves, with Undo next to it — no Save button, and the sheet stays open so you can carry on
- **Aisle scanning is gone.** Photographing the directory board made layouts worse, not better: the two shops it had been used on had 38 and 39 sections against 18 for the ones it hadn't, overlapping and about one in seven junk. Saying where one thing is beats guessing at forty
- **Seven departments, and only seven** — Produce, Bakery, Deli, Seafood, Meat & Poultry, Dairy & Eggs, Frozen. Eleven others had crept in — Snacks, Baby, Pantry, Canned Goods — and none of them is a place you can walk to. "Condiments & Sauces" is *in* aisle 5; it is not a sign you walk towards
- An item with no known aisle now says **"No aisle yet"** and stays there until somebody says otherwise. The app no longer guesses, and no longer offers to guess again at something it has already failed
- What it does suggest comes from what has actually been recorded at that shop — taco seasoning in aisle 4 is what puts cinnamon there next time
- Swipe an aisle right to rename it. Items in it stay in it
- Delete a department you do not have, and type its name back in later to get the real one back
- Numbered aisles sit in numeric order — 4 goes between 3 and 5, not after 10
- Map Aisles now lists the items it could not place, with the numbers right there to place them
- Fix: **aisle management closed itself** every time you added, deleted or reordered an aisle, dropping you back on the store page mid-edit
- Fix: correcting an item to a numbered aisle was accepted on screen and then silently discarded when you pressed Apply
- Fix: renaming a store wrote back the aisle layout the screen had opened with, quietly undoing every aisle added since

### Your shops
- **Every household now has a Deli/Bodega.** Some shops have nowhere to walk to — a fridge, a counter, shelves. It has no aisles, so there is no mapping step, no aisle screen, and the list is one plain "TO GET". Strip any shop's departments and you get the same thing
- Two shops can no longer share a name. They are indistinguishable everywhere a shop appears, and each carries its own aisles, so picking the wrong one sends you to the wrong place
- A shop with no layout says so, rather than reporting "0 sections" like something half set up
- Fix: creating a shop listed it twice

### Your list
- Fix: **the app crashed** when deleting an item from suggestions
- Fix: the delete confirmation appeared and vanished on its own, and the item looked deleted when it never was. Nothing was ever lost
- Fix: saving an aisle by voice closed the whole item screen out from under you

### Your household
- **Invite by QR.** The square is under the code on the invite screen; the join screen scans it. Most invites happen in the same room, and a scan cannot mishear a B for a D
- Invite codes are longer and live ten minutes instead of thirty. Nobody waits half an hour to join a shopping list, and any member can make a new one in a tap
- Fix: the shared invite message claimed the code lasted 24 hours. It had not for a long time

### Privacy
- **There is a privacy policy**, at got-dill.com/privacy, linked before you create an account and in Settings. It says plainly what is stored, who in your household can see it, and the two things that leave your phone — dictated audio and list text. Aisle speech is recognised on the phone and never sent anywhere
- **Server logs no longer record what is on your list.** They had been writing the parsed list, the product name sent for an aisle guess, and the whole sign-in event. Now they record that a request happened, which household it belonged to, how large it was, how long it took and whether it failed — and nothing about the contents
- Logs are kept for 90 days instead of forever

### Elsewhere
- Fix: **hold-to-talk captured nothing.** Letting go cancelled the recogniser before it had delivered the words, which on a one-word answer was all of them. The microphone permission was also never actually requested
- Every screen does one job again: the mid-trip store switcher is gone, and aisle management no longer lists items


## [1.7.0] - 2026-08-31

### Your list
- **Quantities are gone.** A shopping list says what to buy, not how much — "2 cups flour" is now just Flour, and "Eggs x12" is Eggs. What kind still survives, because it changes which packet you pick up: unsalted butter, waxy potatoes, plain flour
- The name under each item is tinted in that person's own colour, so who added what is readable at a glance instead of being the same grey for everyone
- Everyone is given a colour automatically. Tap your badge in Settings to pick a different one from twelve — a colour someone else already has wears their initial, so it's clear why you can't take it
- The main list is always alphabetical now, which answers "is milk already on here?" without reading every row. Sorting moved to suggestions, where hundreds of rows make it worth having
- Messages like "Tomatoes is already on your list" get their own full-width line instead of being cut off inside the header
- While someone is out shopping, the list now says it's locked, who has it, and that it ends when they finish — rather than offering to send them requests that go nowhere

### Aisles
- Aisles default to the order you walk the shop: produce, bakery, deli, then the fish and meat counters, then dairy, then the store's numbered aisles, with frozen last
- Dragging aisles into your own order now sticks, reordering can no longer lose an aisle, and aisles can be deleted with a swipe
- Section headers say which aisle, not what's on the shelf — no more "12 - SYRUP, TEA BAGS, CHOCOLATE SYRUP…" three lines deep. Stores already scanned are fixed without re-scanning
- Aisle names read as names everywhere, and whatever the field shows can be typed straight back in
- Fix: saving an item to a named department like Bakery said "Aisle saved" and quietly did nothing. The two items this had broken are repaired
- Fix: an aisle save that fails now says so and keeps what you typed, instead of disappearing without a word
- Fix: the same aisle no longer appears twice in a row, with its items split between two identical headings
- Fix: an AI-suggested aisle showed its storage name — "standard-produce" rather than Produce — when you opened an item
- Tap a row in Map Aisles to change where something goes. It only responded to a long press before, which the hint mentioned in small grey type and nobody read
- The aisle order screen has a Done button. Getting out of it previously meant guessing that you could swipe it away
- "Unknown Aisle" is now "Not sorted yet" — those items aren't in a lost aisle, they just haven't been placed yet
- Creating a store is one screen now: name, chain, done

### Shopping
- Fix: "Nothing crossed off in a while" no longer arrives mid-trip on a weak signal. It counts what you ticked off, not what reached the server
- Fix: the "someone is shopping" banner clears on a pull-to-refresh instead of needing the app restarted
- Fix: dictated lists no longer end with "Thank you for watching"

### Your household
- An invite code now admits one person and expires after thirty minutes, instead of working over and over for a day for anyone the text was forwarded to
- **Generate New Code** was failing silently every time it was pressed. It works, and the code's expiry is shown
- The email invitation form is gone. Copy and Share hand the code to whatever you actually use
- **Delete Account** in Settings, which removes your sign-in and your profile. Items you added stay on the household list

### Privacy
- Each household's list, stores, aisles and history are now walled off at the server, rather than simply having no button that reaches them
- Photos can no longer be listed by anyone outside the household
- Signing out clears the previous account's list, queued changes and trip stats off the phone

## [1.6.0] - 2026-08-30

### Shopping
- **Quick Trip** is now a scratch list that lives only on this phone — no store, no aisles, nothing shared. Type it, tick it, tap Done and it's gone
- Your main list shows underneath it, collapsed. Tap any item to bring it along; the household list is untouched
- Suggestions sit below that, so a Quick Trip can be filled without typing
- **Share** button on both lists — plain text that survives Messages, WhatsApp and Mail, with what's already in your cart listed separately so nobody buys a second carton of milk
- **Restore last trip** puts a finished list back the way it was. Matches what's already there, so restoring twice doesn't duplicate anything
- The request/approve inbox is gone. Asking someone mid-shop belongs in a text message, not a queue they might never see

### Your track record
- New screen counting trips, items, time in the store, what you buy most, and where you shop
- Kept **on this phone only** — nothing is sent anywhere, and each phone keeps its own
- Starts empty. Nothing is backfilled, so it says so until you finish your first trip

### Aisles
- Aisle names now read as names. "standard-household" was the storage key, not a place in the shop
- Standard departments went from 14 to 18: **Personal Care**, **Pharmacy & Health**, **Baby** and **Pet** split out of Household, so sleep aids no longer file next to the bin bags
- Aisle inference reads the store's own aisle list and can no longer invent sections that don't exist
- Mappings pointing at deleted aisles are pruned instead of quietly re-used
- Scan Directory is hidden for stores marked as having no aisles — there's no board to photograph

### No signal
- Offline is a condition now, not a mode you have to choose. The app notices and carries on
- Changes made without signal are queued and pushed when it returns, instead of silently reverting on the next refresh
- A refresh will no longer overwrite work that hasn't been sent yet

### Elsewhere
- The app is **Got Dill?**

## [1.5.0] - 2026-08-27

### Shopping
- Two ways to shop instead of three: **At Store** for the planned aisle-sorted run, **Quick Trip** for everything else
- Quick Trip now shows your shopping list — tap items to bring them along, or Add all. Anything you don't find goes back on the list; anything you buy is saved as a suggestion
- Finishing a trip with items left asks what to do: keep them (the store didn't have them) or clear them (you got them and didn't tick them off)
- Notes can be marked "Just for this trip" — reminders like "get only 1" clear themselves when shopping finishes
- Adding an item while someone else is shopping now asks them to approve it, so they can say no at the checkout
- Voice button on the At Store search — say an item, tap once, it's on the list

### No signal
- **Paper List** mode: the app stops calling the server entirely — no waiting, no spinners. Cross things off and add items; changes stay on your phone
- Your list is saved on the phone, so it's there instantly even if the app crashes at the store with no reception
- If it can't reach the server on launch it offers the paper list, or keeps retrying quietly in the background

### Adding items
- Speak a whole list naturally — it handles filler, corrections ("cheddar, no wait, mozzarella") and retractions ("actually skip the eggs")
- Say what you're cooking and it suggests the ingredients, grouped in a card you accept or trim — nothing is added without your say-so
- The review list separates what it heard clearly from what it guessed at, showing your own words next to each guess
- Rebuilt the import screen around how you actually add things: Speak, Camera, Photos, Paste — with typing as an option rather than the default
- Your typed or dictated text is no longer lost if you back out by accident

### Elsewhere
- Cleaner list header — it now reports what's happening instead of repeating the screen's name
- Password fields have a show/hide toggle, work with 1Password and iCloud Keychain, and focus on the first tap
- Resetting your password signs you straight in
- Fix: the list no longer reshuffles itself when you reopen the app, or when you enter a store
- Removed per-item emoji reactions

## [1.4.0] - 2026-08-26

- Quick Trip: start a store-less shopping run for a few things you need right now — your main list stays untouched and comes back when you finish
- Quick Trip: pull items off the main list to bring along; anything you don't find returns to the main list automatically, and anything you buy is saved as a suggestion
- Notes can be marked "Just for this trip" — trip-scoped reminders like "get only 1" clear themselves when shopping finishes, while durable notes like "Lactaid" stay
- Fix: the shopping list no longer reshuffles itself when the app is reopened
- Removed per-item emoji reactions

## [1.3.0] - 2026-07-19

- Voice dictation: speak your grocery list in bulk import — transcribed via OpenAI Whisper
- Bulk import: match picker lets you link a parsed item to an existing list item or catalog product before importing
- Abandoned session recovery: if a shopping session sits idle for over an hour, any household member can force-finish it (hold-to-confirm) — cart items return to the list
- Shopper reminder: a "Still shopping?" notification nudges the shopper after 10 minutes with nothing crossed off
- Adding items during an active shopping trip now goes straight onto the list (no approval step) — the shopper sees new items appear live

## [1.2.0] - 2026-05-07

- Bulk import: scan a photo (camera, photo library, or clipboard) — AI extracts grocery items from the image
- Bulk import: AI now extracts qualifiers (e.g. "Red Bell Peppers" → item "Bell Peppers", notes "Red")
- Bulk import: item rows open a detail sheet via the ... button for editing before import
- Bulk import: checkbox toggle requires tapping the checkbox only (not the full row)
- Splash screen shows app version and build datetime
- Fix: import catalog matching now handles singular/plural correctly (e.g. "Carrot" matches "Carrots")
- Lambda: structured logging added for all parse requests and responses

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

[Unreleased]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/compare/v1.7.0...HEAD
[1.7.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.7.0
[1.6.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.6.0
[1.5.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.5.0
[1.4.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.4.0
[1.3.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.3.0
[1.2.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.2.0
[1.1.1]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.1.1
[1.1.0]: git@github.com-benedict:DrBenedictPorkins/NotOurGroceries/releases/tag/v1.1.0
[1.0]: https://github.com/DrBenedictPorkins/NotOurGroceries/releases/tag/v1.0-2[1.0.0]: https://github.com/DrBenedictPorkins/NotOurGroceries/releases/tag/v1.0.0
