# Disc Archive

A small macOS app for archiving game installers (GOG) to write-once DVD and Blu-ray discs.
Design canvas: https://claude.ai/artifact/7RWSCDsxvUxja4FTYAL93U

## What v0.1 does

- **New disc:** drop game folders, pick the media (DVD+R, DVD+R DL, BD-R 25/50, BDXL 100), see what fits.
  One disc at a time; games that need several discs come later.
- **Burn:** checksums → recovery data → disc layout → burn → read back.
  - SHA-256 for every file (`_archive/checksums.sha256`, `shasum -a 256 -c` compatible).
  - par2 recovery data per game (5% or 10%), if `par2` is installed (`brew install par2`).
  - Burns with Apple's DiscRecording framework straight from the folders: UDF, no disc image.
  - Reads every file back from the disc and compares it before calling the disc safe.
- **Archive:** catalogue of burned discs in `~/Archive/discs.json`, search by game name,
  re-check an old disc (insert it, the check starts when it mounts). Due every 3 years.

Checksums and recovery files for each disc are also kept in `~/Archive/Sets/<ID>/`.

## Disc layout

```
<Game folder>/...            the game's files, as they were
_archive/checksums.sha256
_archive/disc.json           this disc's catalogue record
_archive/recovery/*.par2     recovery data, one set per game
_archive/README.txt          how to install, check and repair by hand
```

## Build

```bash
xcodebuild -project DiscArchive.xcodeproj -scheme DiscArchive -configuration Debug -derivedDataPath build/dd build
```

Tests (`-only-testing:DiscArchiveTests/SnapshotTests` with `TEST_RUNNER_SNAPSHOT_DIR=<folder>` renders screens to PNG):

```bash
xcodebuild -project DiscArchive.xcodeproj -scheme DiscArchive -configuration Debug -derivedDataPath build/dd test
```

macOS 14+, no App Sandbox (it needs the burner and `par2`), signed with the Apple Development team.

## Development launch arguments

- `-simulateBurn <folder>`: "burns" by copying the disc layout into a folder, so the whole flow works without a drive.
- `-archiveRoot <folder>`: use another folder than `~/Archive` for the catalogue and sets.
- `-addFolders "/path/a|/path/b"`: pre-fill the new disc.

## Not yet

Covers (jewel case front, Blu-ray 14 mm wrap), games split over several discs, second copy,
repair from recovery data inside the app. Not yet tried with a real burner and blank disc.
