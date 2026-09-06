# site/ — the public page for Got Dill?

A single static page describing the app. No build step, no framework, no
JavaScript: `index.html` carries its own CSS, and the only other files are
screenshots. Serving the folder is the whole deployment.

```bash
python3 -m http.server 8931   # then open http://localhost:8931/
```

## What it is not

It is **read-only**. No forms, no analytics, no third-party requests, nothing
that collects anything. If a change would add any of those, it needs a
conversation first — the page's whole value is that it can be dropped on any
static host and forgotten.

No infrastructure lives here on purpose. There is no bucket definition, no
CloudFront stack and no deploy script, because none has been agreed. Hosting is
a separate decision.

## The other pages

`privacy.html`, `support.html` and `account-deletion.html` live here too, moved
out of `docs/` on 2026-09-05 so that one folder is the entire origin and one sync
deploys all of it.

They are deliberately plain document pages, light and dark aware, and they do not
share this page's dark neon treatment. That is on purpose: App Store review has to
read them, they are reference material rather than a pitch, and legibility beats
consistency here. They now carry a footer link back to `/`, which is what ties
them to the front page.

**Every link between these pages is root-relative** (`/privacy`, `/support`, `/`).
Nothing hard-codes `got-dill.com`, so the whole site can move to another domain
without editing a single page. Keep it that way — the app references the domain in
exactly one place, `AppIdentity.privacyPolicyURL`.

## The invite page

`/invite` hands one comp code to each visitor, so the first hundred households
arrive through a link rather than through individually written emails.

A code handed out is **reserved, not spent**: unredeemed, it returns to the pool
after an hour. That is the whole defence against somebody draining the page —
not making it hard, making it pointless. A scrape costs the batch one hour and
gains the scraper nothing, and it heals without anybody doing anything.

The page is `noindex`, because the point is that you choose who gets the link.

### Not published yet

`website/terms-of-service.md` is a draft that has never gone live, so there is no
`/terms` page. Nothing links to one. If terms are ever published they belong here
as `terms.html`, alongside the rest.

## Screenshots

`assets/shots/` was captured on the iPhone 17 Pro simulator against the
**PhotoAccessTest** household, never the live one. Members were renamed to Sam
and Alex and the store to "Greenway Market" for the capture — an invented name,
so the page does not put a real chain's trademark in marketing material.

Each shot is cropped to remove the status bar and the orange `DEV` badge, which
a debug build draws over the top-left corner. A release build would have neither,
but installing one replaces the app on the simulator and signs the tester out, so
cropping is the cheaper route. The crop offsets are per-screen; recapture with
`xcrun simctl io <udid> screenshot` and re-crop by eye rather than reusing a
number from a different screen.

Images are 620px wide, which is 2× their largest rendered size. Keep the
`width`/`height` attributes accurate when replacing one: they reserve the box
before the image loads, and the global `img { height: auto }` rule depends on
them being right.

## Before the App Store listing goes live

Agreed 2026-09-05, not yet done. The page is written for a pre-launch reader and
says so in three places. All three change on the day the app is public.

1. **The status pill in the hero** (`<p class="status">`), currently "In private
   beta. Not on the App Store yet." This becomes the download link. It is already
   a pill sitting where a call to action belongs, so it should turn into an
   anchor to the App Store listing rather than a new element bolted on beside it.
2. **The first two bullets under "Straight answers"**, currently "It is in a
   private beta with a handful of households. There is no public download yet."
   That bullet goes entirely.
3. **The pricing bullet**, currently "Pricing is not settled, so this page does
   not quote any." Once StoreKit ships there is a real number, and either the
   bullet states it or it goes. See `MONETIZATION.qmd` for what was agreed.

Grep for `private beta` before deploying a launch build; if it returns anything,
the page is still telling people they cannot have it.

**Do not add the App Store link before there is one.** A placeholder href, a
"coming soon" badge or an Apple badge image pointing nowhere is worse than the
honest sentence that is there now. The real URL only exists once the listing does.

## Deploying

The site is live at <https://got-dill.com>. It is a plain S3 bucket behind
CloudFront — no Amplify, no pipeline, nothing watches this folder. Deploying is a
manual copy, and it is deliberately not a script, because the object keys do not
match the filenames.

| Local file | S3 key | Why |
|---|---|---|
| `index.html` | `index.html` | The distribution's DefaultRootObject. |
| `privacy.html` | `privacy` | Live URLs have no extension. |
| `support.html` | `support` | " |
| `account-deletion.html` | `account-deletion` | " |
| `invite.html` | `invite` | " |
| `assets/**` | `assets/**` | Unchanged. |

**A plain `aws s3 sync site/ s3://got-dill-com-site/` is wrong** — it would create
`privacy.html`, which the distribution does not serve, and leave the old
extension-less objects stale. Copy the three document pages to their bare keys by
hand and set `--content-type "text/html; charset=utf-8"` on each, or S3 serves
them as `binary/octet-stream` and the browser downloads them instead of rendering.

```bash
B=got-dill-com-site
AWS_PROFILE=mine aws s3 cp index.html            s3://$B/index.html       --content-type "text/html; charset=utf-8" --cache-control "public, max-age=300"
AWS_PROFILE=mine aws s3 cp privacy.html          s3://$B/privacy          --content-type "text/html; charset=utf-8" --cache-control "public, max-age=300"
AWS_PROFILE=mine aws s3 cp support.html          s3://$B/support          --content-type "text/html; charset=utf-8" --cache-control "public, max-age=300"
AWS_PROFILE=mine aws s3 cp account-deletion.html s3://$B/account-deletion --content-type "text/html; charset=utf-8" --cache-control "public, max-age=300"
# invite.html carries a placeholder for the Lambda Function URL and must never
# be uploaded with it unresolved — the page would tell every visitor it is not
# wired up. Substituted at deploy time, never committed with the real URL.
URL=$(AWS_PROFILE=mine aws cloudformation describe-stacks --region us-east-1 \
  --query "Stacks[?contains(StackName,'amplify-d2rsreno8nimo5')].Outputs[?OutputKey=='compCodeHandOutUrl'].OutputValue" --output text | head -1)
[ -n "$URL" ] || { echo "no compCodeHandOutUrl output — is the backend deployed?"; exit 1; }
sed "s|__COMP_CODE_HANDOUT_URL__|$URL|" invite.html > /tmp/invite.html
AWS_PROFILE=mine aws s3 cp /tmp/invite.html          s3://$B/invite           --content-type "text/html; charset=utf-8" --cache-control "public, max-age=60"
AWS_PROFILE=mine aws s3 sync assets/ s3://$B/assets/ --content-type "image/png" --cache-control "public, max-age=86400" --delete
AWS_PROFILE=mine aws cloudfront create-invalidation --distribution-id E12UV51UT41FNP --paths "/*"
```

Distribution `E12UV51UT41FNP`, bucket `got-dill-com-site`, both in `us-east-1`.
`README.md` is never uploaded.
