# Got Dill? — public website content (DRAFT)

Draft copy for the public-facing pages. **Not deployed.** Nothing here has been
reviewed by a lawyer, and every `[BRACKET]` below must be filled in before any of
it goes live.

## Files

| File | What it is |
|---|---|
| ~~`privacy-policy.md`~~ | **Superseded 2026-09-03 and deleted.** The live policy is `docs/privacy.html`, published at <https://got-dill.com/privacy>. Edit that; do not re-add a second copy here. |
| `terms-of-service.md` | Terms of use — accounts, shared households, user content, disclaimers. |
| `support.md` | Support contact plus a short FAQ. App Store review requires a working support URL. |
| `account-deletion.md` | Public description of in-app account deletion. Apple requires this to be documented publicly as well as offered in the app. |
| `README.md` | This file. |

## Placeholders — every one must be replaced

| Placeholder | Appears in | Decision needed |
|---|---|---|
| `[EFFECTIVE DATE]` | privacy-policy, terms-of-service | The date the pages actually go live. Do not backdate. |
| `[SUPPORT EMAIL]` | all four pages | A real, monitored mailbox. App Review will email it. |
| `[LEGAL ENTITY]` | terms-of-service | Who is publishing the app — a person's name or a registered company. Must match the App Store seller name. |
| `[JURISDICTION]` | terms-of-service | Which law governs the terms. Normally where the legal entity is. |
| `[DOMAIN]` | *not currently used* | If a domain is bought, links between pages need to become absolute URLs and the App Store Connect fields need filling in. Listed here so it is not forgotten. |

## Open questions for a human

1. **Retention period.** There is no verified retention policy, so none is stated
   in the privacy policy. Decide how long data is kept after an account is
   deleted (including AWS backups and PITR windows) and write it in.
2. **Legal entity.** Individual developer or a company? This drives
   `[LEGAL ENTITY]`, the App Store seller name, and the liability wording.
3. **Jurisdiction.** Needed for the governing-law clause.
4. **Should a lawyer review this?** Recommended before public release. The draft
   is written to be accurate, not to be defensible.
5. **Does GDPR apply?** If anyone in the EU/UK uses the app, it plausibly does —
   which would bring in a lawful basis, data subject rights, and possibly a
   representative and a processor agreement question. No compliance claim has
   been written into the policy either way; this needs a decision.
6. **Does CCPA/CPRA apply?** Likely turns on revenue and user-count thresholds
   the app is nowhere near today, but revisit before any wide release. Again, no
   claim is made in the policy.
7. **Sub-processor disclosure.** AWS, Anthropic, and OpenAI are named. Confirm
   that matches what the shipping build actually calls, and update this page
   whenever that changes.
8. **Children / age gating.** The policy says the app is not aimed at children.
   Confirm that matches the App Store age rating.
9. **Hosting.** These are plain Markdown. Decide where they render (GitHub Pages,
   Amplify hosting, something else) and whether they need converting to HTML.

## What is deliberately not claimed

- No compliance claims ("GDPR compliant", "CCPA compliant") — unverified.
- No retention period — none exists yet.
- No company name, address, phone number, or registration details — unknown.
- No security certifications.

## Verified in code on 2026-08-31

- The app contacts only AWS, Anthropic and OpenAI. The only other URLs in the
  codebase are a documentation link in a comment and a commented-out OAuth
  callback. No analytics or tracking SDKs are present. (Open question 7 — closed.)
- Dictated audio is not persisted. `transcribeAudioFunction` passes it to OpenAI
  and keeps only the returned text; there is no storage call in that handler.
