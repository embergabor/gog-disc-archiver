# Disc Archive

A small macOS app for archiving game installers (GOG) to write-once DVD and Blu-ray discs.
Design canvas: https://claude.ai/artifact/7RWSCDsxvUxja4FTYAL93U

## What v0.1 does

- **New disc:** drop game folders, pick the media (DVD+R, DVD+R DL, BD-R 25/50, BDXL 100), see the plan.
  Games that don't fit are split over several discs: files are never cut in half, a game too big for one
  disc gets its own discs under one ID (`GOG-014 1/3` … `3/3`, volumes `GOG_014_1` …) that hold only that
  game. Discs fill in your list order (drag to reorder); **Optimise order** rearranges the list for the
  fewest discs when that saves one, with Undo. Between discs the app asks for the
  next blank and starts by itself when one is inserted; **Finish later** keeps the rest of the set
  (`~/Archive/pending.json`) to continue from the New disc screen.
- **Burn:** checksums → recovery data → disc layout → burn → read back.
  - SHA-256 for every file (`_archive/checksums.sha256`, `shasum -a 256 -c` compatible).
  - par2 recovery data per game (5% or 10%), if `par2` is installed (`brew install par2`).
  - Burns with Apple's DiscRecording framework straight from the folders: UDF, no disc image.
  - Reads every file back from the disc and compares it before calling the disc safe.
- **Saved lists:** Save list… keeps a prepared New disc list (order, titles, editions, disc type) in
  `~/Archive/Lists` to burn later; open it from the sidebar. Burned lists are marked, not deleted.
- **Titles:** the pencil on a game sets your own title (shown everywhere, used to search for the cover).
- **Archive:** catalogue of burned discs in `~/Archive/discs.json`, search by game name,
  re-check an old disc (insert it, the check starts when it mounts). Due every 3 years.

- **Game info and covers:** each folder is matched in GOG's public catalog by its `setup_*.exe` name
  (the Steam Deck GOG installer's parsing and exact-match rules). Covers use portrait box art only:
  Steam's 600×900 library cover on an exact title match, else GOG's 342×482 cover, else one made from
  GOG's wide art with the title on a band. Print covers (New disc, the burn screens, or Archive → Print covers…) makes an A4 PDF, also before
  or while burning. New disc shows a live preview of each planned Blu-ray case; drag games in Contents to
  change their order on the front grid and the back. The PDF:
  a folding jewel case booklet (240 × 120 mm, games inside, box art front; fold in half, one-sided printing) or a Blu-ray 14 mm case wrap (271.7 × 148.4 mm)
  with box art and ID on the front (a grid of every game's cover on multi-game discs), ID on the spine,
  and the games with developer, year, genres, build, size and GOG's description on the back.

Checksums and recovery files for each disc are also kept in `~/Archive/Sets/<ID>/`; game info and art
in `~/Archive/Info/`, cover PDFs in `~/Archive/Covers/`.

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

Second copy,
repair from recovery data inside the app. Not yet tried with a real burner and blank disc.
