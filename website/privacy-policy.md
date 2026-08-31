# Privacy Policy — Got Dill?

**Effective date:** [EFFECTIVE DATE]

Got Dill? is a shared grocery list app. A few people in a household join the same
list and add things to it. This page explains what the app stores, where it goes,
and how to get rid of it.

## What we collect

**Your account**
- Email address
- Display name
- A profile colour you pick

**Your list**
- Item names and any notes you add to them
- Photos you attach to items
- Store names, addresses, and the aisle layouts your household enters
- Photos of store aisle-directory boards, which you upload so the app can read
  the text off them

That is the whole list. There is no advertising in the app. There are no
analytics or tracking SDKs. We do not sell your data, and we do not share it with
anyone except the processors named below.

## What stays on your phone

"Track record" trip statistics are stored only on your device. They are never
uploaded to us or to anyone else. If you delete the app, they are gone.

## Who processes your data

Three companies handle data on our behalf. Each one only gets what it needs to do
its job.

**Amazon Web Services** — hosting, database, sign-in, and file storage. Your
account, your list, your photos, and your store layouts live here. All of it is
in the AWS `us-east-1` region in the United States. Sign-in is handled by AWS
Cognito.

**Anthropic** — the app sends text and photos to Claude for two things: turning
what you type or dictate into list items (including reading a recipe photo), and
guessing which aisle a product is likely to be in. Photos of aisle-directory
boards are sent there to have their text extracted.

**OpenAI** — if you dictate an item instead of typing it, the audio is sent to
OpenAI's Whisper service (`gpt-4o-mini-transcribe`) to be turned into text. The
recording is not stored: it is passed straight through, and only the text that
comes back is kept.

## Sharing inside a household

A household is shared on purpose. Everyone in your household can see the list,
the items, the notes, the photos attached to items, and the store layouts.
Anything you add is visible to the other members. Your display name and profile
colour are visible to them too.

## Deleting your account

You can delete your account in the app: **Settings → Danger Zone → Delete my
account**.

Deleting removes your sign-in and your user record. Items you added stay with the
household, because the rest of your household is still using the list. If you are
the last member of the household, the household and all of its data are deleted
along with you.

See [Account Deletion](account-deletion.md) for the full description.

## Children

Got Dill? is not aimed at children.

## Changes to this policy

If this policy changes, the new version will be posted here with a new effective
date.

## Contact

Questions about your data: [SUPPORT EMAIL]
