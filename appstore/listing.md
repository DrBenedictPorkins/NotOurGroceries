# App Store listing — Got Dill?

Draft copy for App Store Connect. Nothing here is submitted. Character limits are
Apple's and are counted in the tables below.

## Fields that are already settled

| Field | Value |
|---|---|
| Name (30) | `Got Dill?` — 9 |
| Support URL | <https://got-dill.com/support> — live |
| Marketing URL | <https://got-dill.com> — live |
| Privacy Policy URL | <https://got-dill.com/privacy> — live |
| Primary category | Food & Drink |
| Secondary category | Productivity |
| Age rating | 4+ — no user-generated public content, no ads, no purchases yet |

## Subtitle (30 chars)

> One list, everyone's phone

26 characters. Says the primary claim, matches the site's hero, and does not
waste the slot repeating the name.

Alternates: `The list your house shares` (26), `Sorted by your shop's aisles`
(28) — the last one leads with the secondary feature, so only use it if the
first claim moves.

## Promotional text (170 chars, editable without a new build)

> Early access. The first hundred households get everything unlocked, for good.
> Install, enter your code, and the whole app is yours.

Rewrite this the day the comp codes run out — it is the one field that can change
without shipping a build.

## Keywords (100 chars, comma separated, no spaces after commas)

```
shopping list,grocery,groceries,household,shared,aisle,supermarket,family,errands,pantry
```

89 characters. Deliberately excludes "Got Dill" and "dill" — the name is already
indexed from the title, and spending keyword budget on it is waste. Excludes
competitor names.

## Description (4000 chars)

> One shopping list your whole household writes on, live, from every phone in the
> house.
>
> Add something and it is on the other phone before you have put yours down. No
> sending it, no sync button, no second copy quietly going stale. Every line says
> who put it there, so a mystery item has someone to ask.
>
> AT THE SHOP
> Say you have arrived and the list regroups under that shop's aisles, in the
> order you actually walk it. Not a generic supermarket — the one on your corner,
> with the aisles it really has, in the sequence you move through it. Tick things
> off as you go. Everyone else can see a trip is underway, so nobody comes home
> with a second bag of onions.
>
> YOUR SHOPS, IN YOUR ORDER
> Drag the aisles into the order you walk them. That order is yours; it is not a
> chain-wide floor plan and it does not reset because the shop moved the crisps.
> Tell it once where something lives and it remembers, for you and for everyone
> else in the house. Keep as many shops as you use, each with its own layout. A
> corner shop with nothing worth mapping is allowed to just be a list.
>
> ADD IT HOWEVER SUITS
> Type it, say it out loud, photograph a recipe, or paste a wall of text and let
> the app pull the items out. Attach a photo to anything the words will not
> cover. Add a note that expires when the trip does.
>
> HAND IT TO A GUEST
> Someone who does not live with you offers to do the shop. Hold up a square,
> they point their phone at it, and your list lands on theirs — without joining
> your household, seeing your history, or seeing anything you write afterwards.
>
> NOT EVERY ERRAND IS A BIG SHOP
> A quick trip is a scratch list that lives on your phone, syncs nowhere and
> never turns into a suggestion. And if a trip ends at the wrong shop or gets cut
> short, putting the list back is one tap.
>
> Finished trips become suggestions, so next week is mostly tapping things you
> already buy instead of spelling them out again.

## What only a human can supply

1. **Unlisted App Distribution.** Requested from Apple by form, for an app that
   already exists in App Store Connect. This is the long pole — start it first.
   Unlisted does **not** skip App Review.
2. **Demo account for App Review.** The app is entirely behind a login, so review
   will reject without working credentials in the App Review notes. Give a real
   account in a household that already has a shop, aisles and a few items —
   an empty account shows a reviewer nothing and invites a rejection for
   incomplete functionality.
3. **App Privacy questionnaire.** Answer honestly: email for the account, photos
   the user attaches, and usage diagnostics. Nothing is sold, nothing is used for
   tracking across apps.
4. **Export compliance.** HTTPS only, no proprietary cryptography, so the
   standard exemption applies.
5. **Screenshots.** See below.

## Screenshots

The old set in `docs/screenshots/` is dead — it predates the rename, shows the
previous blue theme, a "TonyDanza" display name, a DEV badge and v1.4.0, and is
1179x2556, which is not an accepted upload size.

Regenerate on **iPhone 16 Pro Max** (`F950D6A2-03A2-470C-B1AA-D498347EFD86`),
which produces **1320x2868** — the 6.9" size Apple asks for.

Build **Release**, not Debug: the orange DEV badge is `#if DEBUG`, so a Release
build simply does not have it and no source edit is needed. Release uses bundle
id `com.byteclub.grocery.app`, a separate install from the dev app, so it needs
signing in once.

Pin the status bar first, or every shot carries a different clock:

```bash
xcrun simctl status_bar <UDID> override --time "9:41" \
  --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
```

Do not crop these. App Store screenshots must be exactly 1320x2868, so the status
bar stays in frame — which is why it is worth overriding rather than cropping,
unlike the marketing site's screenshots in `site/assets/shots/`.
