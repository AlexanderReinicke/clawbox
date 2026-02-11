# Distribution

## Goal

Produce a `.dmg` that users can download and drag to Applications.

## Build and Archive

```bash
./packaging/archive_release.sh
```

This creates an Xcode archive at `build/ClawMarket.xcarchive` by default.

## Export App

Use Xcode Organizer to export signed app (Developer ID) from the archive, or export an unsigned app for internal testing.

## Create DMG

```bash
./packaging/create_dmg.sh /path/to/ClawMarket.app /path/to/ClawMarket.dmg
```

Example using Debug build output:

```bash
./packaging/create_dmg.sh "$HOME/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/ClawMarket.app" "/tmp/ClawMarket-debug.dmg"
```

## Signing and Notarization (recommended)

1. Sign app with Developer ID Application certificate.
2. Notarize with `notarytool`.
3. Staple ticket to app (and optionally DMG).
4. Recreate DMG from notarized app.

## Verification checklist

- App launches on a machine without Xcode.
- Runtime install flow works (if runtime absent).
- Initial setup (image build + container create/start) completes.
- Terminal opens and commands run.
- Stop/start preserves installed tools and files.
