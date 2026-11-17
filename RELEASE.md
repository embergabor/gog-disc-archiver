# Release checklist

How to put a signed, notarized build of GOG Disc Archiver on GitHub Releases.

## One-time setup (all done)

- [x] Public GitHub repo with MIT licence, README and screenshots
- [x] App icon
- [x] Hardened runtime on, App Sandbox off (fine outside the App Store)
- [x] `gh` logged in to GitHub
- [x] Apple Developer Program membership (team 679574875X)
- [x] **Developer ID Application** certificate in the keychain
  - Made on developer.apple.com → Certificates → **+** → *Developer ID Application*, from a certificate request created in Keychain Access.
  - Check: `security find-identity -v -p codesigning`
- [x] **Notary login** saved as keychain profile `notary`, using an app-specific password from account.apple.com
  - Check: `xcrun notarytool history --keychain-profile notary`
- [x] `scripts/release.sh`, test-run on 0.1. Notarization was accepted, and the download passes Gatekeeper.

## Every release

- [ ] Bump the version in Xcode: `MARKETING_VERSION` (0.1, 0.2, …) and `CURRENT_PROJECT_VERSION` (1, 2, …).
- [ ] Run the tests. Make sure no burn is running first.
- [ ] Commit and push.
- [ ] Run the release script. Notarization usually takes a few minutes.

  ```bash
  scripts/release.sh --publish
  ```

  It builds and signs the app and has Apple notarize it. Then it packs the app into `dist/GOG-Disc-Archiver-<version>.dmg` with an Applications shortcut, and signs and notarizes the DMG too. Last, it creates a **draft** release `v<version>` on GitHub with the DMG attached.
  - Without `--publish` it stops after the DMG, with nothing uploaded.
- [ ] On GitHub, open the draft release, add a few lines of release notes (what's new, what's fixed) and press **Publish release**.
- [ ] Download the DMG from the release page, open it, drag the app to Applications and open it. It should open with no "unidentified developer" warning.

## Good to know

- The script refuses to run if:
  - there are uncommitted changes
  - the commit isn't pushed (with `--publish`)
  - a release for this version already exists.
- The release asset is a DMG (`GOG-Disc-Archiver-<version>.dmg`, volume "GOG Disc Archiver"). The app inside is `GOG Disc Archiver.app`, bundle ID `com.embergabor.GOGDiscArchiver`. The README's Install section says to drag it to Applications.
- Both the app and the DMG carry their own notarization ticket, so they open even without an internet connection.
- Without notarization, downloads are blocked by Gatekeeper on other Macs. The Apple Development certificate only works for local builds.
- The Developer ID certificate is valid for 5 years. The app-specific password stays valid until you revoke it, or until you change your Apple ID password.
- If notarization is rejected, the script prints Apple's log with the reason.
