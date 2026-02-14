import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { listManagedInstances } from "./instances";
import { getRuntimeStatus, resolveContainerBinary } from "./runtime";
import type { InstanceInfo } from "./types";

const DAEMON_PID_PATH = path.join(os.tmpdir(), "clawbox-powerd.pid");
const POLL_MS = 5000;

export async function ensurePowerDaemonRunning(): Promise<void> {
  if (process.platform !== "darwin") {
    return;
  }
  if (await hasLiveDaemon()) {
    return;
  }

  const entrypoint = resolveCliEntrypoint();
  const child = spawn(process.execPath, [entrypoint, "__powerd"], {
    detached: true,
    stdio: "ignore"
  });
  child.unref();
}

export async function runPowerDaemonLoop(): Promise<void> {
  if (process.platform !== "darwin") {
    return;
  }
  const claimed = await claimDaemonPid();
  if (!claimed) {
    return;
  }

  let caffeinate: ChildProcess | undefined;
  const stopCaffeinate = () => {
    if (!caffeinate) {
      return;
    }
    try {
      caffeinate.kill("SIGTERM");
    } catch {
      // Ignore already-dead child process.
    }
    caffeinate = undefined;
  };

  const shutdown = async () => {
    stopCaffeinate();
    await clearDaemonPidIfOwned();
    process.exit(0);
  };

  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
  process.on("SIGHUP", () => void shutdown());

  while (true) {
    const shouldHold = await shouldKeepHostAwake();
    if (shouldHold && !caffeinate) {
      caffeinate = spawn("caffeinate", ["-ims"], { stdio: "ignore" });
      caffeinate.on("close", () => {
        caffeinate = undefined;
      });
    } else if (!shouldHold && caffeinate) {
      stopCaffeinate();
    }
    await sleep(POLL_MS);
  }
}

function shouldUseKeepAwake(instance: InstanceInfo): boolean {
  return instance.keepAwake !== false;
}

async function shouldKeepHostAwake(): Promise<boolean> {
  try {
    const containerBin = await resolveContainerBinary();
    if (!containerBin) {
      return false;
    }

    const runtime = await getRuntimeStatus(containerBin);
    if (!runtime.running) {
      return false;
    }

    const instances = await listManagedInstances(containerBin);
    return instances.some((instance) => instance.status === "running" && shouldUseKeepAwake(instance));
  } catch {
    return false;
  }
}

async function hasLiveDaemon(): Promise<boolean> {
  const pid = await readDaemonPid();
  if (!pid) {
    return false;
  }
  return isProcessAlive(pid);
}

async function claimDaemonPid(): Promise<boolean> {
  const existingPid = await readDaemonPid();
  if (existingPid && existingPid !== process.pid && isProcessAlive(existingPid)) {
    return false;
  }
  await fs.promises.writeFile(DAEMON_PID_PATH, `${process.pid}\n`, "utf8");
  return true;
}

async function clearDaemonPidIfOwned(): Promise<void> {
  const pid = await readDaemonPid();
  if (pid === process.pid) {
    try {
      await fs.promises.unlink(DAEMON_PID_PATH);
    } catch {
      // Ignore best-effort cleanup failures.
    }
  }
}

async function readDaemonPid(): Promise<number | undefined> {
  try {
    const raw = await fs.promises.readFile(DAEMON_PID_PATH, "utf8");
    const parsed = Number(raw.trim());
    if (!Number.isInteger(parsed) || parsed <= 1) {
      return undefined;
    }
    return parsed;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return undefined;
    }
    return undefined;
  }
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function resolveCliEntrypoint(): string {
  const entrypoint = process.argv[1];
  if (!entrypoint) {
    throw new Error("Unable to resolve CLI entrypoint for power daemon startup.");
  }
  return path.isAbsolute(entrypoint) ? entrypoint : path.resolve(process.cwd(), entrypoint);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
