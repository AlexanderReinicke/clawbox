# Runbook

## Build

```bash
cd ClawMarket
xcodebuild -project ClawMarket.xcodeproj -scheme ClawMarket -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

## Runtime precheck

```bash
container --version
container system status
```

Expected: `apiserver is running`.

## Local validation targets

1. Launch app and verify `AgentManager.sync()` resolves runtime/image/container state.
2. Build image from bundled `Dockerfile`.
3. Create/start `claw-agent-1`.
4. Open embedded terminal and run `whoami`, `pwd`, `openclaw --version`.
5. Stop/start container and verify persistence.

## Access folder mount behavior

- Host folder access is provided via bind mount to `/mnt/access`.
- Mounts are applied only when creating the container.
- If you change the selected host folder later, recreate the agent container from the app so the new mount is applied.

## Common failures

- Runtime not installed:
  - Ensure `/usr/local/bin/container` exists.
- Runtime not started:
  - Run `container system start`.
- Node memory OOM in guest:
  - Confirm container memory and `NODE_OPTIONS` are set.
- `openclaw` missing after image build:
  - Ensure Dockerfile installs `openclaw` before `USER agent`.
  - Rebuild image and verify with:
    - `container exec -i claw-agent-1 /bin/bash -lc 'which openclaw && openclaw --version'`

## Logs

- Agent command log:
  - `~/Library/Logs/ClawMarket/agent.log`
- Rotation:
  - current log rolls to `agent.log.1` around 1 MB.
