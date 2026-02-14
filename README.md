# clawbox

Run OpenClaw on your Mac with a safer default.

`clawbox` launches OpenClaw workloads inside isolated Linux VMs and limits host access to only the folder you choose.

## Launch Focus: OpenClaw, But Safer

OpenClaw is powerful. The risk is usually not OpenClaw itself, it is the environment around it.

`clawbox` is built to solve that by default:
- Isolated VM per OpenClaw workspace.
- Explicit single-folder host mount (`--mount /path`).
- Localhost-safe Control UI access (`clawbox ui`) to avoid common gateway/websocket issues.
- Optional keep-awake mode for long OpenClaw runs.

## Who This Is For

- OpenClaw users who do not want bots touching their whole laptop.
- Teams running multiple OpenClaw projects and needing clean separation.
- Security-minded builders who want practical isolation without complex infra.

## Safety Model

What `clawbox` protects:
- OpenClaw runs in a VM, not directly on your host.
- Only mounted host paths are accessible from inside the VM.
- You can isolate every OpenClaw bot/project in its own VM.

What it does not magically protect:
- Anything inside mounted folders is intentionally accessible to that VM.
- If you mount sensitive files, OpenClaw can read them.

Best practice:
- Mount one narrow project folder.
- Keep secrets outside mounted paths.
- Use one VM per trust boundary (project/client/env).

## Requirements

- macOS 26+ (Darwin 25+)
- Apple Silicon (arm64)
- Apple `container` CLI installed
- Node.js 18+

## Install

```bash
npm install -g clawbox
```

## OpenClaw Safe Start (5 Minutes)

1. Validate host/runtime:

```bash
clawbox doctor
```

2. Create an OpenClaw VM with one mounted folder:

```bash
clawbox create openclaw-main --mount ~/work/my-openclaw-project
```

`clawbox create` will ask whether to keep the Mac awake while this VM runs.

3. Start VM and open shell:

```bash
clawbox start openclaw-main
clawbox shell openclaw-main
```

4. Inside the VM, install OpenClaw (helper is preinstalled):

```bash
openclaw-install
```

5. From your Mac, open OpenClaw Control UI safely:

```bash
clawbox ui openclaw-main
```

Use the localhost URL it prints.

## Workflow Blocks

### Block 1: New OpenClaw Workspace (safe-by-default)

```bash
clawbox doctor
clawbox create openclaw-main --mount ~/work/my-openclaw-project
clawbox start openclaw-main
clawbox shell openclaw-main
# inside VM:
openclaw-install
```

### Block 2: Daily OpenClaw Session

```bash
clawbox start openclaw-main
clawbox shell openclaw-main
clawbox ui openclaw-main
```

### Block 3: Change Power Mode (long jobs vs battery)

```bash
clawbox power openclaw-main --keep-awake
# or
clawbox power openclaw-main --allow-sleep
```

### Block 4: End Session / Cleanup

```bash
clawbox pause openclaw-main
# when fully done with this workspace:
clawbox delete openclaw-main --yes --confirm-name openclaw-main
```

## Why `clawbox ui` Matters

OpenClaw Control UI is most reliable when accessed through localhost.

`clawbox ui` creates a localhost proxy and opens:
- `http://127.0.0.1:<port>/`

This avoids the typical LAN-IP websocket/auth failures people hit with direct VM IP browsing.

## Power Policy For Long OpenClaw Sessions

Set at create time:

```bash
clawbox create openclaw-main --keep-awake
# or
clawbox create openclaw-main --allow-sleep
```

Change later anytime:

```bash
clawbox power openclaw-main --keep-awake
clawbox power openclaw-main --allow-sleep
```

## OpenClaw-Centric Daily Workflow

```bash
clawbox ls
clawbox start openclaw-main
clawbox shell openclaw-main
clawbox ui openclaw-main
clawbox inspect openclaw-main
clawbox pause openclaw-main
```

Delete a VM safely:

```bash
clawbox delete openclaw-main --yes --confirm-name openclaw-main
```

## Commands

```bash
clawbox about [--watch|--once]
clawbox doctor
clawbox create [name] [--ram <gb>] [--mount <path>] [--keep-awake|--allow-sleep] [--yes]
clawbox ls
clawbox start <name>
clawbox pause <name>
clawbox power <name> [--keep-awake|--allow-sleep]
clawbox shell <name> [--yes] [--new-terminal]
clawbox ui <name> [--port 18789] [--yes] [--no-open]
clawbox inspect <name>
clawbox delete <name> [--yes --confirm-name <name>]
```

## Troubleshooting

If runtime is down:

```bash
container system start
clawbox doctor
```

If Control UI fails:
- Use `clawbox ui <name>` instead of direct VM LAN IP.
- Keep the `clawbox ui` process running while using the dashboard.

## Development

```bash
npm install
npm run typecheck
npm run build
node dist/cli.js about --once
```

## License

MIT
