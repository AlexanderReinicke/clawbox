import chalk from "chalk";
import { Command } from "commander";
import { HOST_RAM_FLOOR_GB, RAM_OPTIONS_GB } from "../lib/constants";
import { runCommand } from "../lib/exec";
import { listManagedInstances } from "../lib/instances";
import { hostFreeRamGb, hostTotalRamGb, sumAllocatedRamGb } from "../lib/ram-policy";
import { getRuntimeStatus, resolveContainerBinary } from "../lib/runtime";
import { roundTo } from "../lib/utils";

interface AboutOptions {
  watch?: boolean;
  once?: boolean;
  interval?: string;
}

interface AboutSnapshot {
  containerInstalled: boolean;
  runtimeRunning: boolean;
  runtimeStateLabel: string;
  totalRamGb: number;
  hostFreeRamGb: number;
  instanceCount: number;
  runningCount: number;
  allocatedAllGb: number;
  allocatedRunningGb: number;
}

export function registerAboutCommand(program: Command): void {
  program
    .command("about")
    .description("Show clawbox runtime status and RAM headroom")
    .option("-w, --watch", "Live update in terminal")
    .option("--once", "Print one snapshot and exit")
    .option("--interval <seconds>", "Refresh interval in seconds", "1")
    .action(async (options: AboutOptions) => {
      const intervalSeconds = parseIntervalSeconds(options.interval);
      const watch = options.once ? false : (options.watch ?? process.stdout.isTTY);

      if (watch) {
        console.log(chalk.dim("Live mode enabled. Press Ctrl+C to stop."));
      }

      do {
        const snapshot = await captureAboutSnapshot();
        if (watch && process.stdout.isTTY) {
          process.stdout.write("\x1Bc");
        }

        renderSnapshot(snapshot, watch);

        if (!watch) {
          return;
        }

        await sleep(intervalSeconds * 1000);
      } while (true);
    });
}

async function captureAboutSnapshot(): Promise<AboutSnapshot> {
  const totalRamGb = hostTotalRamGb();
  const liveFreeGb = await hostAvailableRamGb();

  const containerBin = await resolveContainerBinary();
  if (!containerBin) {
    return {
      containerInstalled: false,
      runtimeRunning: false,
      runtimeStateLabel: "container CLI not installed",
      totalRamGb,
      hostFreeRamGb: liveFreeGb,
      instanceCount: 0,
      runningCount: 0,
      allocatedAllGb: 0,
      allocatedRunningGb: 0
    };
  }

  try {
    const runtime = await getRuntimeStatus(containerBin);
    if (!runtime.running) {
      return {
        containerInstalled: true,
        runtimeRunning: false,
        runtimeStateLabel: "runtime stopped",
        totalRamGb,
        hostFreeRamGb: liveFreeGb,
        instanceCount: 0,
        runningCount: 0,
        allocatedAllGb: 0,
        allocatedRunningGb: 0
      };
    }

    const instances = await listManagedInstances(containerBin);
    const allocatedAllGb = sumAllocatedRamGb(instances, "all");
    const allocatedRunningGb = sumAllocatedRamGb(instances, "running");
    const runningCount = instances.filter((instance) => instance.status === "running").length;

    return {
      containerInstalled: true,
      runtimeRunning: true,
      runtimeStateLabel: "running",
      totalRamGb,
      hostFreeRamGb: liveFreeGb,
      instanceCount: instances.length,
      runningCount,
      allocatedAllGb,
      allocatedRunningGb
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return {
      containerInstalled: true,
      runtimeRunning: false,
      runtimeStateLabel: `runtime check failed: ${message}`,
      totalRamGb,
      hostFreeRamGb: liveFreeGb,
      instanceCount: 0,
      runningCount: 0,
      allocatedAllGb: 0,
      allocatedRunningGb: 0
    };
  }
}

function renderSnapshot(snapshot: AboutSnapshot, watch: boolean): void {
  const policyAvailableGb = roundTo(snapshot.totalRamGb - snapshot.allocatedAllGb, 2);
  const policyHeadroomGb = roundTo(Math.max(0, policyAvailableGb - HOST_RAM_FLOOR_GB), 2);
  const presetsAvailable = RAM_OPTIONS_GB.filter((ram) => ram <= policyHeadroomGb);

  console.log(chalk.bold("clawbox status"));
  console.log(`updated: ${new Date().toLocaleTimeString()}`);

  if (!snapshot.containerInstalled) {
    console.log(chalk.red("runtime: container CLI not installed"));
    console.log("install: https://github.com/apple/container/releases/latest");
    console.log("next: container system start");
    return;
  }

  const runtimeLabel = snapshot.runtimeRunning
    ? chalk.green(snapshot.runtimeStateLabel)
    : chalk.yellow(snapshot.runtimeStateLabel);

  console.log(`runtime: ${runtimeLabel}`);
  console.log(`instances: ${snapshot.instanceCount} total (${snapshot.runningCount} running)`);
  console.log(`host RAM: ${snapshot.totalRamGb} GB total`);
  console.log(`host free now (live): ${colorLiveFree(snapshot.hostFreeRamGb)} GB`);
  console.log(`clawbox allocated (all): ${snapshot.allocatedAllGb} GB`);
  console.log(`clawbox allocated (running): ${snapshot.allocatedRunningGb} GB`);
  console.log(`policy available (total - allocated): ${policyAvailableGb} GB`);
  console.log(`policy headroom above ${HOST_RAM_FLOOR_GB} GB floor: ${policyHeadroomGb} GB`);
  console.log(`quick create sizes currently allowed: ${presetsAvailable.length > 0 ? presetsAvailable.join(", ") + " GB" : "none"}`);

  if (watch) {
    console.log("");
    console.log(chalk.dim("Refreshing... Ctrl+C to stop."));
  }
}

function colorLiveFree(freeGb: number): string {
  if (freeGb < HOST_RAM_FLOOR_GB) {
    return chalk.red(String(freeGb));
  }
  if (freeGb < HOST_RAM_FLOOR_GB + 2) {
    return chalk.yellow(String(freeGb));
  }
  return chalk.green(String(freeGb));
}

function parseIntervalSeconds(input?: string): number {
  if (!input) {
    return 1;
  }

  const seconds = Number(input);
  if (!Number.isFinite(seconds) || seconds <= 0) {
    throw new Error("--interval must be a positive number.");
  }
  return seconds;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function hostAvailableRamGb(): Promise<number> {
  if (process.platform !== "darwin") {
    return hostFreeRamGb();
  }

  try {
    const result = await runCommand("vm_stat", [], { timeoutMs: 3000 });
    return parseVmStatAvailableGb(result.stdout);
  } catch {
    return hostFreeRamGb();
  }
}

function parseVmStatAvailableGb(output: string): number {
  const lines = output.split("\n");
  const pageSizeLine = lines.find((line) => line.toLowerCase().includes("page size of"));
  const pageSize = pageSizeLine ? extractFirstInt(pageSizeLine) : undefined;
  if (!pageSize) {
    return hostFreeRamGb();
  }

  const wantedKeys = ["pages free", "pages inactive", "pages speculative"];
  let availablePages = 0;

  for (const line of lines) {
    const normalized = line.toLowerCase();
    const matched = wantedKeys.some((key) => normalized.includes(key));
    if (!matched) {
      continue;
    }
    const value = extractFirstInt(line);
    if (typeof value === "number") {
      availablePages += value;
    }
  }

  if (availablePages <= 0) {
    return hostFreeRamGb();
  }

  const availableBytes = availablePages * pageSize;
  return roundTo(availableBytes / (1024 ** 3), 2);
}

function extractFirstInt(input: string): number | undefined {
  const match = input.match(/([0-9][0-9,.]*)/);
  if (!match) {
    return undefined;
  }
  const numeric = Number(match[1].replace(/[,.]/g, ""));
  return Number.isFinite(numeric) ? numeric : undefined;
}
