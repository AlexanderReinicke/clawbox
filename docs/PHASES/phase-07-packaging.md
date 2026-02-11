# Phase 7 - Packaging + Distribution

## Scope

Added repeatable packaging and release documentation.

## What was implemented

- Added packaging script:
  - `packaging/create_dmg.sh`
  - creates drag-and-drop style DMG from a `.app` bundle.
- Added archive helper:
  - `packaging/archive_release.sh`
  - runs Xcode archive command for Release builds.
- Added distribution documentation:
  - `docs/DISTRIBUTION.md`
  - build/archive/export/notarization checklist and DMG flow.
- Updated docs map to include distribution guide.

## Why this design

- Packaging should be scriptable and reproducible, not purely manual.
- Explicit distribution docs reduce handoff friction for future maintainers.

## Validation

- Packaging scripts are executable and ready for use.
- DMG creation path verified against local debug app bundle:
  - output: `/tmp/ClawMarket-debug-direct.dmg`

## Files

- `packaging/create_dmg.sh`
- `packaging/archive_release.sh`
- `docs/DISTRIBUTION.md`
- `docs/README.md`
