# clawbox CLI

`clawbox` is a TypeScript CLI for managing isolated Linux VM instances through Apple's `container` runtime.

## Requirements

- macOS 26+ (Darwin 25+), Apple Silicon
- Apple `container` CLI installed and available on `PATH`
- Node.js 18+
- 16 GB host RAM recommended (8 GB host reserve is enforced)

## Install

```bash
npm install -g clawbox
# or
npx clawbox about
```

GitHub install script:

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/scripts/install.sh | bash
```

## Commands

```bash
clawbox about
clawbox doctor
clawbox create <name> [--ram 4|5|6|<custom>] [--mount /path] [--yes]
clawbox ls
clawbox start <name>
clawbox pause <name>
clawbox shell <name> [--yes] [--new-terminal]
clawbox inspect <name>
clawbox delete <name>
```

`clawbox about` runs in live mode in interactive terminals. Use `clawbox about --once` for a single snapshot.

`clawbox start` and `clawbox shell` now auto-ensure OpenClaw gateway health when OpenClaw exists in the instance. If OpenClaw is not installed, they continue normally and show a skip notice.

## RAM policy

Before `create` and `start`, clawbox enforces:

`total host RAM - allocated clawbox RAM - requested RAM >= 8 GB`

If the result is below 8 GB, the command is rejected with explicit math.

## Default template

Template Dockerfile lives at `templates/default/Dockerfile` and is built locally on first create.

The v1 template is Debian (Node 22 Bookworm Slim) with common tooling preinstalled:

- bash, curl, wget, git, openssh-client, jq
- python3 + pip
- nodejs 22.x + npm
- nano, vim, htop, ripgrep, fd
- build-base + cmake

OpenClaw is intentionally **not preinstalled** in this template. An `openclaw-install` helper is included inside instances.

## Development

```bash
npm install
npm run build
npm run typecheck
node dist/cli.js about
```
