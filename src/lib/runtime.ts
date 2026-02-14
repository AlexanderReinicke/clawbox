import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { MIN_SUPPORTED_DARWIN_MAJOR } from "./constants";
import { runCommand } from "./exec";

const CONTAINER_BINARY_CANDIDATES = [
  process.env.CLAWBOX_CONTAINER_BIN,
  "/usr/local/bin/container",
  "/opt/homebrew/bin/container"
].filter((value): value is string => Boolean(value));

export interface RuntimeStatus {
  running: boolean;
  rawStatus: string;
}

export interface HostCompatibility {
  os: string;
  arch: string;
  darwinMajor?: number;
  supported: boolean;
  reason?: string;
}

export async function resolveContainerBinary(): Promise<string | null> {
  for (const candidate of CONTAINER_BINARY_CANDIDATES) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  const whichResult = await runCommand("which", ["container"], { allowNonZeroExit: true, timeoutMs: 5000 });
  if (whichResult.exitCode === 0 && whichResult.stdout) {
    const resolved = whichResult.stdout.split("\n")[0].trim();
    if (resolved) {
      return resolved;
    }
  }

  return null;
}

export async function requireContainerBinary(): Promise<string> {
  const binary = await resolveContainerBinary();
  if (binary) {
    return binary;
  }

  throw new Error(
    "Apple container CLI was not found. Install it from the Apple container release page, then run `container system start`."
  );
}

export async function getContainerVersion(containerBin: string): Promise<string> {
  const result = await runCommand(containerBin, ["--version"], { timeoutMs: 10_000 });
  return result.stdout || "unknown";
}

export async function getRuntimeStatus(containerBin: string): Promise<RuntimeStatus> {
  const result = await runCommand(containerBin, ["system", "status"], { allowNonZeroExit: true, timeoutMs: 15_000 });
  const raw = [result.stdout, result.stderr].filter(Boolean).join("\n").trim();
  return {
    running: isRuntimeRunning(raw),
    rawStatus: raw || "unknown"
  };
}

export async function ensureRuntimeRunning(containerBin: string): Promise<void> {
  const current = await getRuntimeStatus(containerBin);
  if (current.running) {
    return;
  }

  await runCommand(containerBin, ["system", "start"], { timeoutMs: 60_000 });
  const next = await getRuntimeStatus(containerBin);
  if (!next.running) {
    throw new Error("Container runtime is not running. Try `container system start` manually and retry.");
  }
}

export function isRuntimeRunning(rawStatus: string): boolean {
  const normalized = rawStatus.toLowerCase();
  return normalized.includes("apiserver is running") || normalized.includes("running");
}

export function getHostCompatibility(): HostCompatibility {
  const platform = process.platform;
  const arch = process.arch;
  if (platform !== "darwin") {
    return {
      os: platform,
      arch,
      supported: false,
      reason: "clawbox only supports macOS"
    };
  }
  if (arch !== "arm64") {
    return {
      os: platform,
      arch,
      supported: false,
      reason: "clawbox requires Apple Silicon (arm64)"
    };
  }

  const darwinMajor = parseDarwinMajor(os.release());
  if (typeof darwinMajor === "number" && darwinMajor < MIN_SUPPORTED_DARWIN_MAJOR) {
    return {
      os: platform,
      arch,
      darwinMajor,
      supported: false,
      reason: `clawbox requires macOS 26+ (Darwin ${MIN_SUPPORTED_DARWIN_MAJOR}+)`
    };
  }

  return {
    os: platform,
    arch,
    darwinMajor,
    supported: true
  };
}

function parseDarwinMajor(release: string): number | undefined {
  const value = release.split(".")[0];
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : undefined;
}

export function getTemplateDockerfilePath(): string {
  const candidates = [
    path.resolve(__dirname, "../../templates/default/Dockerfile"),
    path.resolve(__dirname, "../templates/default/Dockerfile"),
    path.resolve(process.cwd(), "templates/default/Dockerfile")
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error("Bundled default template Dockerfile not found.");
}
