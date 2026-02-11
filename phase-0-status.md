# Phase 0 Status (2026-02-11)

## Completed

- Machine requirements verified:
  - `uname -m`: `arm64`
  - `sw_vers`: macOS `26.2`
  - `xcodebuild -version`: Xcode `26.0.1`
- Installed Apple container CLI:
  - `container CLI version 0.9.0`
  - `container system status`: apiserver running
- Lifecycle persistence verified with long-running command model:
  - Used `container run -d --name lifecycle-test <image> sleep infinity`
  - Created `/root/test.txt` with content `persistence test`
  - Restarted container and confirmed file persisted
- OpenClaw runtime compatibility verified:
  - `openclaw` requires Node `>=22.12.0`
  - Successful path: `node:22-bookworm-slim` + `npm install -g openclaw@2026.2.9`
  - Verified: `openclaw --version` => `2026.2.9`
  - OOM mitigation validated: `NODE_OPTIONS=--max-old-space-size=768`
- Active ready-to-use test container:
  - `lifecycle-test` is running on `node:22-bookworm-slim`
  - `openclaw@2026.2.9` installed and executable
- Dockerfile build flow verified:
  - Built image `clawmarket/default:latest`
  - Started `build-test` from that image
  - Verified process user/home:
    - `whoami` => `agent`
    - `pwd` => `/home/agent`
- Phase 0.9 scaffold created in repo:
  - `ClawMarket/ClawMarketApp.swift`
  - `ClawMarket/Models/AgentManager.swift`
  - `ClawMarket/Views/*.swift` placeholders
  - `ClawMarket/Resources/Dockerfile`
- Cleanup done:
  - `build-test` removed
  - superseded exploratory containers removed (`openclaw-*`)
  - `lifecycle-test` intentionally kept running for immediate use

## Notes

- `openclaw` on Alpine is unreliable due to native/toolchain + glibc expectations.
- Default image should be Debian + Node 22 for reliable `openclaw` installs.
- Low-memory containers can OOM on startup; baseline is `-m 4096M`, with `-m 2048M` only as constrained fallback plus `NODE_OPTIONS`.
- See `phase-0-learnings.md` for full known-good commands and rationale.

## Quick Recovery Checklist

1. Recreate a known-good runtime container:

```bash
container rm lifecycle-test 2>/dev/null || true
container run -d --name lifecycle-test -m 4096M node:22-bookworm-slim sleep infinity
container exec -i lifecycle-test bash -lc 'apt-get update && apt-get install -y git python3 make g++ cmake'
container exec -i lifecycle-test bash -lc 'npm install -g openclaw@2026.2.9'
```

2. Apply Node heap fix and verify:

```bash
container exec -i lifecycle-test bash -lc 'echo "export NODE_OPTIONS=--max-old-space-size=768" >> /root/.bashrc'
container exec -i lifecycle-test bash -lc 'export NODE_OPTIONS=--max-old-space-size=768; openclaw --version'
```

3. Start gateway for host-browser access:

```bash
container exec -i lifecycle-test bash -lc 'kill -9 $(pgrep -f "openclaw gateway") 2>/dev/null || true'
container exec -i lifecycle-test bash -lc 'export NODE_OPTIONS=--max-old-space-size=768; nohup openclaw gateway --bind lan > /tmp/openclaw-gateway.log 2>&1 &'
container ls -a
```

4. If Control UI shows secure-context/device errors (dev only):

```bash
container exec -i lifecycle-test bash -lc 'openclaw config set gateway.controlUi.allowInsecureAuth true --json'
container exec -i lifecycle-test bash -lc 'openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true --json'
container exec -i lifecycle-test bash -lc 'kill -9 $(pgrep -f "openclaw gateway") 2>/dev/null || true; export NODE_OPTIONS=--max-old-space-size=768; nohup openclaw gateway --bind lan > /tmp/openclaw-gateway.log 2>&1 &'
```

5. Auth token for UI:

```bash
container exec -i lifecycle-test bash -lc 'openclaw config get gateway.auth.token'
```

Paste that token into Control UI settings, then connect.

6. Dev-only auth rollback when done:

```bash
container exec -i lifecycle-test bash -lc 'openclaw config set gateway.controlUi.allowInsecureAuth false --json'
container exec -i lifecycle-test bash -lc 'openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth false --json'
container exec -i lifecycle-test bash -lc 'kill -9 $(pgrep -f "openclaw gateway") 2>/dev/null || true; export NODE_OPTIONS=--max-old-space-size=768; nohup openclaw gateway --bind lan > /tmp/openclaw-gateway.log 2>&1 &'
```

## Remaining (manual in Xcode)

- Create `ClawMarket` macOS SwiftUI project (macOS 26.0 target).
- Add Swift package dependency: `https://github.com/migueldeicaza/SwiftTerm`.
- Configure Signing & Capabilities:
  - App Sandbox OFF
  - Hardened Runtime ON
  - `com.apple.security.network.client = YES`
- Add `Dockerfile` as bundled resource.
