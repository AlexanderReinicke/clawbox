import os from "node:os";
import { DEFAULT_RAM_GB, HOST_RAM_FLOOR_GB } from "./constants";
import type { InstanceInfo, RamPolicyComputation } from "./types";
import { roundTo } from "./utils";

export type AllocationMode = "all" | "running";

export function hostTotalRamGb(): number {
  return roundTo(os.totalmem() / (1024 ** 3), 2);
}

export function hostFreeRamGb(): number {
  return roundTo(os.freemem() / (1024 ** 3), 2);
}

export function sumAllocatedRamGb(
  instances: InstanceInfo[],
  mode: AllocationMode,
  excludeInternalName?: string
): number {
  const total = instances.reduce((acc, instance) => {
    if (excludeInternalName && instance.internalName === excludeInternalName) {
      return acc;
    }

    if (mode === "running" && instance.status !== "running") {
      return acc;
    }

    const value = typeof instance.ramGb === "number" ? instance.ramGb : DEFAULT_RAM_GB;
    return acc + value;
  }, 0);

  return roundTo(total, 2);
}

export function evaluateRamPolicy(totalGb: number, allocatedGb: number, requestedGb: number): RamPolicyComputation {
  const remainingGb = roundTo(totalGb - allocatedGb - requestedGb, 2);
  return {
    totalGb: roundTo(totalGb, 2),
    allocatedGb: roundTo(allocatedGb, 2),
    requestedGb: roundTo(requestedGb, 2),
    remainingGb,
    reserveFloorGb: HOST_RAM_FLOOR_GB,
    allowed: remainingGb >= HOST_RAM_FLOOR_GB
  };
}

export function ramPolicyError(computation: RamPolicyComputation): string {
  return [
    "RAM policy violation:",
    `  total RAM: ${computation.totalGb} GB`,
    `  currently allocated: ${computation.allocatedGb} GB`,
    `  requested: ${computation.requestedGb} GB`,
    `  remaining after operation: ${computation.remainingGb} GB`,
    `  required minimum remaining: ${computation.reserveFloorGb} GB`,
    "Operation rejected because host free RAM would fall below the 8 GB floor."
  ].join("\n");
}
