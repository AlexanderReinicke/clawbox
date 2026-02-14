#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="clawbox-package"
PACKAGE_SPEC="${1:-${PACKAGE_NAME}@latest}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "clawbox only supports macOS (Darwin)."
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "clawbox requires Apple Silicon (arm64)."
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js 18+ is required. Install Node.js and retry."
  exit 1
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "${NODE_MAJOR}" -lt 18 ]]; then
  echo "Node.js 18+ is required. Current: $(node -v)"
  exit 1
fi

DARWIN_MAJOR="$(uname -r | cut -d. -f1)"
if [[ "${DARWIN_MAJOR}" -lt 25 ]]; then
  echo "clawbox requires macOS 26+ (Darwin 25+). Current Darwin: ${DARWIN_MAJOR}"
  exit 1
fi

TOTAL_MEM_BYTES="$(sysctl -n hw.memsize)"
TOTAL_MEM_GB="$(( TOTAL_MEM_BYTES / 1024 / 1024 / 1024 ))"
if [[ "${TOTAL_MEM_GB}" -lt 16 ]]; then
  echo "clawbox requires at least 16 GB host RAM. Detected: ${TOTAL_MEM_GB} GB"
  exit 1
fi

if ! command -v container >/dev/null 2>&1; then
  echo "Apple container CLI is not installed."
  echo "Run these commands:"
  echo "  curl -fL -o /tmp/container-installer-signed.pkg https://github.com/apple/container/releases/latest/download/container-installer-signed.pkg"
  echo "  sudo installer -pkg /tmp/container-installer-signed.pkg -target /"
  echo "  container system start"
  exit 1
fi

echo "Installing ${PACKAGE_SPEC}..."
npm install -g "${PACKAGE_SPEC}"

STATUS_OUTPUT="$(container system status 2>&1 || true)"
if [[ "${STATUS_OUTPUT}" != *"apiserver is running"* ]]; then
  echo "Starting Apple container runtime..."
  container system start
fi

echo "Install complete."
echo "Running first-install checks..."
clawbox doctor
echo "Run: clawbox about"
