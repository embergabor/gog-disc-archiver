# GOG Disc Archiver: notes for Claude

macOS 14+ SwiftUI app that burns GOG installer folders straight to data BD/DVD (no disc images), verifies every file by reading it back, keeps a catalogue of burned discs, splits big games across discs and prints case covers. The README covers usage.

## Layout

- `GOGDiscArchiver/App`: `AppModel` (@Observable, all app state) and the app entry point. `Features.recovery = false` hides par2 recovery data; the code stays in place.
- `Engine/`: planning (`DiscPlanner`, `DiscLayout`), burning (`DiscWriter`, `BurnJob`, `BurnSession` for multi-disc sets), `Checksums` (SHA-256), `Verifier` (read-back), `GameInfoService` (title, art and details lookup), `Par2`, `DriveMonitor`, `BurnEstimate`.
- `Covers/`: `CoverViews` (cover layouts and themes, crop and cut marks) and `CoverBuilder` (PDF output).
- `Storage/`: `Catalogue` (`~/Archive`) and `SavedLists` (`~/Archive/Lists`).
- `Views/`: one file per screen.
- The Xcode project is hand-written and uses synchronized folders, so new files need no project edits. Team 679574875X, bundle `com.embergabor.GOGDiscArchiver`, hardened runtime, App Sandbox off.

## Build and test

```bash
xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Debug -derivedDataPath build/dd test -skip-testing:GOGDiscArchiverTests/LiveLibraryTests -skip-testing:GOGDiscArchiverTests/LiveLookupTests
```

- `LiveLookupTests` and `LiveLibraryTests` use the network and `~/Downloads/GOG`; run them only when lookup code changes.
- README screenshots (written to `build/shots`, then copied to `docs/screenshots/`). They use a temporary copy of `~/Archive`:

  ```bash
  TEST_RUNNER_SCREENSHOT_DIR=$PWD/build/shots xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Debug -derivedDataPath build/dd test -only-testing:GOGDiscArchiverTests/ScreenshotTests
  ```

- UI checks: no computer-use access to this app. Check screens through `SnapshotTests` / `ScreenshotTests` renders and look at the PNGs.
- Dev launch arguments: `-archiveRoot <dir>` (default `~/Archive`), `-simulateBurn <dir>`, `-addFolders "a|b"`. The test catalogue is `~/Archive-Test`.

## While a real burn is running

Don't touch the app, the drive or the USB connection: no relaunching, no tests (the test host launches the app), no `drutil`. Compiling is fine, but only into a separate folder:

```bash
xcodebuild -project GOGDiscArchiver.xcodeproj -scheme GOGDiscArchiver -configuration Debug -derivedDataPath build/dd-dev build-for-testing
```

## Git

- Commit locally. Push only when asked.
- Port 22 can time out here, so push over 443:

  ```bash
  GIT_SSH_COMMAND='ssh -o Hostname=ssh.github.com -o Port=443 -o HostKeyAlias=github.com -o BatchMode=yes -o ConnectTimeout=15' git push
  ```

- The repo is public (MIT). Keep personal data out of it, and strip EXIF from photos before adding them (`exiftool -all= -overwrite_original`).

## Product rules (decided by the user)

- **Distribution:** GitHub releases only (Developer ID + notarization). The Mac App Store is ruled out.
- **Icons:** monochrome only, in the UI and in mockups.
- **Titles:** a game's title comes from the installer's ProductName (PE version info), not GOG's current store title. If ProductName is cut off (60 chars), use the GOG title. The pencil sets a custom title, which is also used as the lookup term. Editions are a separate optional label (e.g. "Next Gen").
- **Lookup order:** GOG catalogue exact match, then gogdb.org (delisted games), then a relaxed main-title match. Steam art only on an exact title match. Loose matches may only drop ` - ` / ` — ` suffixes, never cut at a colon (that's how Fallout once got the New Vegas cover). Ambiguous loose matches are refused.
- **Cover art:** portrait box art only, never landscape. Multi-game fronts show a grid of every game's cover.
- **Disc order:** discs follow the user's list order (drag to reorder). **Optimise order** only reorders the list, appears only when it saves a disc, and can be undone.
- **Splitting:** a game too big for one disc gets discs of its own (`GOG-014 1/3` …), whole files only, and the last disc is never topped up with other games. A single file bigger than the disc is an error.
- **No disc images:** burn straight from the folders via DiscRecording. Burning stops if a source file changed size after it was added.
- **Covers:** purple design (#4B2A7F) with disc-groove rings. Ink saver = white front. "Brighten box art for print" is on by default. The jewel booklet is one-sided (no duplex printer). Print at 100%, with dotted cut lines and crop marks.

## Pending

- `scripts/release.sh`: archive, export with Developer ID, notarize (`notarytool` keychain profile `notary`), staple, build a DMG, then `gh release create v0.1`. Waiting until the user has created the Developer ID Application certificate (on developer.apple.com via a CSR, because Xcode's "+" fails) and stored the notary credentials.
