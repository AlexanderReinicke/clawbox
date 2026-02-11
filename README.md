# ClawMarket

ClawMarket is a macOS SwiftUI app that provisions and manages a persistent Linux agent container using Apple's `container` runtime, then exposes an embedded terminal into that container.

## Current functionality

- Runtime detection and startup (`container system status/start`).
- Guided first-run flow:
  - Welcome
  - Runtime install (automatic + manual fallback)
  - Template launch and setup progress
  - Home controls
- Container lifecycle management:
  - image build
  - container create/start/stop/delete
  - factory reset
- Embedded SwiftTerm terminal attached to:
  - `container exec -i -t claw-agent-1 /bin/bash`
- Error handling with retry/reset/copy-error.
- Agent command logging with rotation.

## Project docs

See `docs/README.md` for architecture, decisions, runbook, distribution, and per-phase implementation notes.

## Build

```bash
cd ClawMarket
xcodebuild -project ClawMarket.xcodeproj -scheme ClawMarket -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Packaging

```bash
./packaging/create_dmg.sh /path/to/ClawMarket.app /path/to/ClawMarket.dmg
```
