# Decisions (ADR-lite)

## D-001: Use Debian Node base instead of Alpine

- Status: accepted
- Context: `openclaw` install/runtime failed or was unstable on Alpine due to native dependency + glibc/toolchain expectations.
- Decision: use `node:22-bookworm-slim` and pin `openclaw@2026.2.9`.
- Consequence: larger base image than Alpine, but stable install/runtime.

## D-002: Default container memory baseline is 2 GB

- Status: accepted
- Context: low-memory containers can OOM during `openclaw` startup.
- Decision: set `-m 2048M` for baseline; recommend `-m 4096M` for heavier workloads.
- Consequence: higher default memory footprint but significantly better startup stability.

## D-003: Build app control plane around shelling out to `container` CLI

- Status: accepted
- Context: Apple `container` CLI already encapsulates image/container lifecycle behavior we need.
- Decision: use `Process`-based shell execution with timeout/error capture.
- Consequence: robust CLI parsing and process lifecycle handling are critical.

## D-004: Use SwiftTerm for embedded terminal

- Status: accepted
- Context: product requires interactive in-app shell with copy/paste and resize behavior.
- Decision: integrate `SwiftTerm` (`LocalProcessTerminalView`) and attach to `container exec`.
- Consequence: AppKit bridge required (`NSViewRepresentable`) for SwiftUI integration.

## D-005: Automate runtime installation from the app

- Status: accepted
- Context: users may not have Apple `container` runtime installed.
- Decision: add an in-app installer flow (download pkg + admin install + runtime start) with manual fallback.
- Consequence: first-run UX is simpler, but requires robust error handling around privileged operations.

## D-006: Install OpenClaw before switching to non-root user in Dockerfile

- Status: accepted
- Context: installing `openclaw` after `USER agent` causes permission errors writing `/usr/local/lib/node_modules`.
- Decision: run `npm install -g openclaw@2026.2.9` as root, then switch to `agent`.
- Consequence: image build remains reproducible and `openclaw` is available in `/usr/local/bin` for the runtime user.
