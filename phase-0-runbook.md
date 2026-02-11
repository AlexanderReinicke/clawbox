# ClawMarket Phase 0 Runbook

Use this file as the exact manual checklist for Phase 0.

## 1. Verify machine requirements

```bash
uname -m
sw_vers
xcodebuild -version
```

Expected:
- `arm64`
- macOS 26.x
- Xcode 26.x

## 2. Install Apple `container` CLI

Note: the old `0.8.0` URL is dead. Use `0.9.0`.

```bash
cd /tmp
curl -fL -o container-installer-signed.pkg \
  https://github.com/apple/container/releases/download/0.9.0/container-installer-signed.pkg
sudo installer -pkg /tmp/container-installer-signed.pkg -target /
```

## 3. Start runtime and verify

```bash
container system start
container --version
container system status
```

If first startup asks to install Linux kernel, answer `Y`.

If `container` command is missing:

```bash
which container
echo $PATH
```

## 4. Test lifecycle persistence + OpenClaw install (critical)

Use Node 22 on Debian. `openclaw` currently requires Node >= 22.12.0.

```bash
container rm lifecycle-test 2>/dev/null || true
container run -d --name lifecycle-test -m 2048M node:22-bookworm-slim sleep infinity
container ls -a
container exec -i -t lifecycle-test /bin/sh
```

Use `-m 4096M` if you plan heavier OpenClaw workloads.

Inside shell:

```sh
apt-get update
apt-get install -y git python3 make g++ cmake
npm install -g openclaw@2026.2.9
export NODE_OPTIONS=--max-old-space-size=768
openclaw --version
echo "persistence test" > /root/test.txt
exit
```

Back on host:

```bash
container stop lifecycle-test
container start lifecycle-test
container exec -i -t lifecycle-test /bin/sh
```

Verify inside:

```sh
cat /root/test.txt
which openclaw
openclaw --version
exit
```

Cleanup:

```bash
container stop lifecycle-test
container rm lifecycle-test
```

## 5. Test `container build` with Dockerfile

```bash
mkdir -p /tmp/clawtest
cat > /tmp/clawtest/Dockerfile << 'EOF'
FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y \
    bash curl wget git openssh-client jq python3 python3-pip \
    nano vim htop ripgrep fd-find make g++ cmake \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash agent
USER agent
WORKDIR /home/agent
RUN echo 'PS1="agent@claw:\w\$ "' >> /home/agent/.bashrc
RUN npm install -g openclaw@2026.2.9
ENV NODE_OPTIONS=--max-old-space-size=768
CMD ["sleep", "infinity"]
EOF

container build -t clawmarket/default:latest /tmp/clawtest
container image ls
container run -d --name build-test clawmarket/default:latest
container exec -i -t build-test /bin/bash
```

Expected: bash prompt as user `agent`.
Verify inside container shell:

```bash
node -v
openclaw --version
```

Cleanup:

```bash
container stop build-test
container rm build-test
```

## 6. Xcode project setup (manual)

1. Create new macOS app:
   - Interface: SwiftUI
   - Language: Swift
   - Product Name: `ClawMarket`
   - Organization: `com.clawmarket`
   - Deployment target: macOS 26.0
2. Add Swift package dependency:
   - `https://github.com/migueldeicaza/SwiftTerm`
3. Signing & Capabilities:
   - App Sandbox: OFF
   - Hardened Runtime: ON
   - Add entitlement: `com.apple.security.network.client = YES`
4. Add Dockerfile to app bundle resources.
5. Create placeholder files/folders from Phase 0.9.

## 7. If something jams

Run these and share outputs:

```bash
container --version
container system status
container image ls
```

If `container system start` appears hung for a long time:

```bash
container system stop || true
container system start
```

Then retry the verification commands above.

If OpenClaw says `Gateway: not detected`:

```bash
export NODE_OPTIONS=--max-old-space-size=768
openclaw gateway --bind lan
```

Then from host, open:

```text
http://<container-ip>:18789
```

(`127.0.0.1` inside container is not the host Mac.)
