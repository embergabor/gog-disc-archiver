# Release checklist

How to put a signed, notarized build of GOG Disc Archiver on GitHub Releases.

## Already done

- [x] Public GitHub repo with MIT licence, README and screenshots
- [x] App icon
- [x] Hardened runtime on, App Sandbox off (fine outside the App Store)
- [x] `gh` logged in to GitHub
- [x] Apple Developer Program membership (team 679574875X)

## One-time setup (you)

- [ ] **Developer ID Application certificate.** Xcode's "+" button fails for this, so do it by hand:
  1. Keychain Access → Certificate Assistant → *Request a Certificate From a Certificate Authority…* → enter your email, choose *Saved to disk*.
  2. developer.apple.com → Certificates → **+** → *Developer ID Application* → upload the `.certSigningRequest` file.
  3. Download the certificate and double-click it to add it to your keychain.
  4. Check: `security find-identity -v -p codesigning` lists **Developer ID Application: …**.
- [ ] **App-specific password** for notarization: account.apple.com → Sign-In and Security → App-Specific Passwords. Copy it.
- [ ] **Save the notary login** in the keychain, using the password from the previous step:

  ```bash
  xcrun notarytool store-credentials notary --apple-id YOUR_APPLE_ID --team-id 679574875X
  ```

  Check: `xcrun notarytool history --keychain-profile notary` runs without an error.

Tell Claude when these three are done.

## One-time setup (Claude)

- [ ] Write `scripts/release.sh`. It will:
  - build a Release archive
  - export it signed with Developer ID
  - notarize and staple it
  - zip it
  - create the GitHub release.

## Every release

- [ ] Bump the version in Xcode: `MARKETING_VERSION` (0.1, 0.2, …) and `CURRENT_PROJECT_VERSION` (1, 2, …).
- [ ] Run the tests. Make sure no burn is running first.
- [ ] Commit and push.
- [ ] Run `scripts/release.sh`. Notarization usually takes a few minutes.
- [ ] Check the zip on the release page: download it, unzip it and open the app. It should open with no "unidentified developer" warning.
  - `spctl -a -vv "GOG Disc Archiver.app"` should say **Notarized Developer ID**.
- [ ] Add a few lines of release notes on GitHub: what's new and what's fixed.

## Good to know

- The README's Install section says "download, unzip, move to Applications", so the release asset is a `.zip`, not a DMG.
- Without notarization, downloads are blocked by Gatekeeper on other Macs. The Apple Development certificate only works for local builds.
- The certificate is valid for 5 years. The app-specific password stays valid until you revoke it.
