# Orttaai DMG Release Guide

This guide produces a signed, notarized DMG that users can download and install on macOS.

## 1. One-time setup

1. Install a **Developer ID Application** certificate in Xcode:
   - `Xcode > Settings > Accounts > Manage Certificates`

2. Create an app-specific password (Apple ID account settings).

3. Save notarization credentials in your keychain:

```bash
xcrun notarytool store-credentials "ORTTAAI_NOTARY" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

4. Verify signing identity exists:

```bash
security find-identity -v -p codesigning
```

You should see `Developer ID Application`.

## 2. Build + notarize DMG (one command)

```bash
chmod +x scripts/release_dmg.sh
scripts/release_dmg.sh
```

Artifacts are written to:

- `dist/<version>/Orttaai-<version>.dmg`
- SHA256 is printed at the end.

## 3. Common variants

Override version:

```bash
scripts/release_dmg.sh --version 1.0.1
```

Use a different notary profile:

```bash
scripts/release_dmg.sh --notary-profile MY_NOTARY_PROFILE
```

Build/package only (no notarization):

```bash
scripts/release_dmg.sh --skip-notarize
```

## 4. Publish

1. Upload the DMG to your website (or GitHub Releases, S3, Cloudflare R2, etc.).
2. Publish the SHA256 alongside download links.
3. If you ship Homebrew cask updates, update `orttaai.rb` with the new version and SHA.
4. If Sparkle updates are enabled in-app, generate/update `Orttaai/Resources/appcast.xml`.

## 5. Troubleshooting

- `Developer ID Application signing identity not found`
  - Install the certificate in Xcode and retry.

- `Notary profile ... not found or invalid`
  - Re-run `xcrun notarytool store-credentials ...` and verify team ID/password.

- Gatekeeper assessment fails
  - Ensure notarization completed successfully and stapling ran:
    - `xcrun stapler staple dist/<version>/Orttaai-<version>.dmg`
    - `spctl --assess --type open --verbose=4 dist/<version>/Orttaai-<version>.dmg`
