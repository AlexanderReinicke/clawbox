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
3. Select Agent 1 and create/start `claw-agent-1`.
4. Add Agent 2 slot, select it, create/start `claw-agent-2`.
5. Open embedded terminal and run `whoami`, `pwd`, `openclaw --version`.
6. Stop/start selected container and verify persistence.

## Access folder mount behavior

- Host folder access is provided via bind mount to `/mnt/access`.
- Mounts are applied only when creating the container.
- Access folder selection is per agent slot.
- If you change the selected folder for a slot later, recreate that same agent slot so the new mount is applied.

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
- Gateway shows `not detected` after restart:
  - App start flow now auto-configures gateway mode/token + control-ui auth flags and starts gateway.
  - For containers created before this fix, run `Recreate Agent` once so the new startup behavior is applied consistently.

## Logs

- Agent command log:
  - `~/Library/Logs/ClawMarket/agent.log`
- Rotation:
  - current log rolls to `agent.log.1` around 1 MB.
