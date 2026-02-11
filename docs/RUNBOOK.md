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

## Common failures

- Runtime not installed:
  - Ensure `/usr/local/bin/container` exists.
- Runtime not started:
  - Run `container system start`.
- Node memory OOM in guest:
  - Confirm container memory and `NODE_OPTIONS` are set.

## Logs

- Agent command log:
  - `~/Library/Logs/ClawMarket/agent.log`
- Rotation:
  - current log rolls to `agent.log.1` around 1 MB.
