# Publishing to the Chrome Web Store (unlisted) and wiring the app

## 1. One-time: developer account
1. Go to the [Chrome Web Store Developer Dashboard](https://chrome.google.com/webstore/devconsole) and sign in with the Google account that should own the item.
2. Pay the one-time **$5** registration fee and verify the contact email.

## 2. Build the upload package
```bash
scripts/package-extension.sh      # → build/subline-extension-<version>.zip (manifest "key" stripped)
scripts/build-app.sh && scripts/store-assets.sh   # → store/assets/*.png (screenshots, promo tile)
```

## 3. Create the item
1. Dashboard → **New item** → upload the zip.
2. **Store listing:** fill it in from [LISTING.md](LISTING.md) and upload the icon, screenshots and promo tile.
3. **Privacy practices:** single purpose, permission justifications and data usage from [LISTING.md](LISTING.md). Publish [PRIVACY.md](PRIVACY.md) at a public URL and paste the link.
4. **Distribution:** visibility **Unlisted**.
5. **Submit for review.** It usually takes from a few days to a couple of weeks.

## 4. After approval: connect the app to the store ID
The dashboard shows the item ID (32 letters a–p), for example `abcdefghijklmnopabcdefghijklmnop`.

```bash
echo abcdefghijklmnopabcdefghijklmnop > keys/store-extension-id.txt
scripts/build-app.sh --install
```

With the ID baked into the app:
- The Native Messaging manifest allows **both** the store ID and the development ID, so unpacked builds keep working.
- The app writes `~/Library/Application Support/Google/Chrome/External Extensions/<id>.json`. On the next Chrome launch, Chrome offers to enable the extension (the user clicks **Enable extension**). Chrome remembers if the user removes it and won't reinstall it.
- The setup window's **Add to Chrome** button opens the store page.

## 5. Updates
Bump `version` in `extension/manifest.json`, then run `scripts/package-extension.sh` and upload the zip under **Package → Upload new package**.
