# Phase 0 Learnings

Date: 2026-02-11

## What worked reliably

- Apple container CLI `0.9.0` installed and runtime started successfully.
- Lifecycle persistence works when container is started with a long-running command:
  - `container run -d --name <name> <image> sleep infinity`
- `openclaw` installs and runs successfully on:
  - Base image: `node:22-bookworm-slim`
  - Node: `v22.22.0`
  - Install command: `npm install -g openclaw@2026.2.9`
  - Verification: `openclaw --version` => `2026.2.9`
  - Runtime stability: set `NODE_OPTIONS=--max-old-space-size=768` (or higher memory container)

## What failed / gotchas

- Old package URL in original plan is dead:
  - `.../container-0.8.0-installer-signed.pkg` returns 404.
  - Use `0.9.0` package URL.
- `container create/start` with `alpine:latest` and no keepalive command can lead to immediate stop.
  - Result: `cannot exec: container is not running`.
- Alpine path for `openclaw` is unreliable:
  - Native dependency chain (`node-llama-cpp`) plus glibc/toolchain expectations causes failures or long unstable builds.
- `openclaw` requires Node `>=22.12.0`.
  - On Node 20, install may succeed but running `openclaw` fails with engine/version error.
- Low-memory container defaults can trigger Node OOM on `openclaw` startup.
  - Observed: 1 GB container + default Node heap limit ~524 MB => immediate OOM.
  - Fix: run container with at least `-m 2048M` and set `NODE_OPTIONS=--max-old-space-size=768` (current app default is `-m 4096M`).
- "Gateway not detected" is usually a local gateway process issue, not internet loss.
  - If no process listens on `127.0.0.1:18789`, status shows gateway unreachable.
  - If gateway binds loopback in-container, host Mac cannot reach it via container IP.
  - Fix: start gateway explicitly and bind `lan` when host access is needed.
- `openclaw gateway --force` failed on slim image because `lsof` was missing.
  - Error: `Force: Error: lsof not found; required for --force`.
  - Fix: stop/kill prior gateway PID first, then start normally.
- Control UI over container IP hit browser-security/auth gates:
  - `disconnected (1008): control ui requires HTTPS or localhost (secure context)`
  - `disconnected (1008): device identity required`
  - Root cause: accessing Control UI via `http://<container-ip>:18789` is not localhost/HTTPS; browser client must provide shared auth and/or device identity unless explicitly relaxed.

## Topology clarification (important)

- Apple `container` is not Docker-style "many containers inside one Linux VM".
- In Apple `container`, each running container has its own lightweight VM boundary.
- For ClawNode UX, "agent slots" must map to separate container names (`claw-agent-1`, `claw-agent-2`, ...), not multiple agents inside one container.
- Terminal, file browser, dashboard, and delete actions should always target the currently selected slot/container.

## Recommended defaults going forward

- Use Debian-based Node 22 image as baseline for ClawMarket default container.
- Default to 4 GB memory (`-m 4096M`) for ClawMarket runtime stability.
- Use 2 GB (`-m 2048M`) only for constrained environments with `NODE_OPTIONS` set.
- Pin `openclaw` version in build/install steps:
  - `npm install -g openclaw@2026.2.9`
- Keep container alive with:
  - `sleep infinity`
- Bake `NODE_OPTIONS=--max-old-space-size=768` into image env.
- For host-browser access, publish dashboard port and prefer localhost:
  - container create should publish unique localhost ports per slot (for example slot 1 -> `127.0.0.1:18789:18789`, slot 2 -> `127.0.0.1:18790:18789`)
  - app should open selected slot localhost URL
  - keep container-IP fallback only for legacy containers without port mapping
- Keep a documented dev-only fallback for Control UI auth friction:
  - `gateway.controlUi.allowInsecureAuth=true`
  - `gateway.controlUi.dangerouslyDisableDeviceAuth=true`
  - In app setup, set these automatically before gateway start to avoid repeated `1008` disconnects.

## Exact session log (what we actually did)

1. Installed runtime:

```bash
curl -fL -o /tmp/container-installer-signed.pkg https://github.com/apple/container/releases/download/0.9.0/container-installer-signed.pkg
sudo installer -pkg /tmp/container-installer-signed.pkg -target /
container system start
container system status
```

2. Found lifecycle issue with Alpine default command exiting immediately.
   - Switched to keepalive `sleep infinity`.

3. Found OpenClaw install/runtime constraints:
   - Alpine path unstable due to native/glibc chain.
   - Node 20 failed runtime check (`openclaw requires Node >=22.12.0`).
   - Stabilized on `node:22-bookworm-slim`.

4. Created working container and installed OpenClaw:

```bash
container run -d --name lifecycle-test -m 2048M node:22-bookworm-slim sleep infinity
container exec -i lifecycle-test bash -lc 'apt-get update && apt-get install -y git python3 make g++ cmake'
container exec -i lifecycle-test bash -lc 'npm install -g openclaw@2026.2.9'
container exec -i lifecycle-test bash -lc 'openclaw --version'
```

5. Hit Node heap OOM on `openclaw` startup in low-memory path.
   - Applied:

```bash
export NODE_OPTIONS=--max-old-space-size=768
```

6. Gateway troubleshooting:
   - `Gateway not detected` because no listener on `18789` or loopback-only bind.
   - Started gateway on LAN bind:

```bash
openclaw gateway --bind lan
```

7. Control UI browser errors and fixes:
   - Error: `control ui requires HTTPS or localhost (secure context)`.
   - For local dev over `http://<container-ip>:18789`, enabled:

```bash
openclaw config set gateway.controlUi.allowInsecureAuth true --json
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth true --json
```

   - Restarted gateway after config changes.

8. Auth sync for CLI/UI:
   - Read gateway token:

```bash
openclaw config get gateway.auth.token
```

   - Synced local remote token used by CLI:

```bash
openclaw config set gateway.remote.token "$(openclaw config get gateway.auth.token)"
```

9. Final reachable state:
   - Gateway listening on `ws://0.0.0.0:18789`
   - Host browser reachable at `http://<container-ip>:18789`

## Dev-only security rollback (when done testing)

```bash
openclaw config set gateway.controlUi.allowInsecureAuth false --json
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth false --json
```

Then restart gateway and prefer HTTPS or localhost path.

## Known-good Phase 0 command sequence

```bash
container run -d --name lifecycle-test -m 4096M node:22-bookworm-slim sleep infinity
container exec -i -t lifecycle-test /bin/sh -lc \
  'apt-get update && apt-get install -y git python3 make g++ cmake && npm install -g openclaw@2026.2.9 && export NODE_OPTIONS=--max-old-space-size=768 && openclaw --version && echo "persistence test" > /root/test.txt'
container stop lifecycle-test
container start lifecycle-test
container exec -i -t lifecycle-test /bin/sh -lc \
  'cat /root/test.txt && openclaw --version'
container stop lifecycle-test
container rm lifecycle-test
```

Gateway startup (inside container):

```bash
export NODE_OPTIONS=--max-old-space-size=768
openclaw gateway --bind lan
```

## Implementation impact

- `ClawMarket/Resources/Dockerfile` should use `node:22-bookworm-slim`, install build deps, install `openclaw@2026.2.9`, and set `NODE_OPTIONS`.
- This removes Alpine-specific blockers and makes setup reproducible.
- `ClawMarket/ClawMarket/Models/AgentManager.swift` default memory is now `4096M` to match the stable baseline.
- `ClawMarket/ClawMarket/Models/AgentManager.swift` dashboard flow now:
  - creates new containers with per-slot localhost dashboard ports
  - auto-sets `gateway.controlUi.allowInsecureAuth=true`
  - auto-sets `gateway.controlUi.dangerouslyDisableDeviceAuth=true`
  - starts gateway with robust process detection (`pgrep -x openclaw-gateway`)
- Multi-agent UI implementation note:
  - slot selection maps to a real container target (`claw-agent-N`) at runtime,
  - slot runtime states are read from `container ls` / `container ls -a`,
  - app-level "container group" is a logical grouping layer, not a nested runtime container,
  - access-folder mount configuration is stored per-agent slot and applied only when that slot is created/recreated.
