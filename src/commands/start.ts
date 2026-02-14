import ora from "ora";
import { Command } from "commander";
import { DEFAULT_RAM_GB } from "../lib/constants";
import { ensureOpenClawGateway, formatGatewayResult } from "../lib/gateway";
import {
  listManagedInstances,
  startManagedInstance,
  waitForInstanceIp
} from "../lib/instances";
import { evaluateRamPolicy, hostTotalRamGb, ramPolicyError, sumAllocatedRamGb } from "../lib/ram-policy";
import { ensureRuntimeRunning, requireContainerBinary } from "../lib/runtime";

export function registerStartCommand(program: Command): void {
  program
    .command("start <name>")
    .description("Start a paused instance")
    .action(async (name: string) => {
      const containerBin = await requireContainerBinary();
      await ensureRuntimeRunning(containerBin);

      const instances = await listManagedInstances(containerBin);
      const instance = instances.find((item) => item.name === name);

      if (!instance) {
        throw new Error(instanceNotFoundMessage(name, instances.map((item) => item.name)));
      }

      if (instance.status === "running") {
        console.log(`Instance '${name}' is already running.`);
        const gateway = await ensureOpenClawGateway(containerBin, instance.internalName);
        console.log(formatGatewayResult(gateway));
        if (instance.ip) {
          console.log(`IP: ${instance.ip}`);
        }
        return;
      }

      const totalRamGb = hostTotalRamGb();
      const allocatedRunningGb = sumAllocatedRamGb(instances, "running", instance.internalName);
      const requestedGb = instance.ramGb ?? DEFAULT_RAM_GB;
      const policy = evaluateRamPolicy(totalRamGb, allocatedRunningGb, requestedGb);
      if (!policy.allowed) {
        throw new Error(ramPolicyError(policy));
      }

      const spinner = ora(`Starting '${name}'...`).start();
      try {
        await startManagedInstance(containerBin, instance.internalName);
        const ip = await waitForInstanceIp(containerBin, instance.internalName);
        spinner.succeed(`Started '${name}'.`);
        const gateway = await ensureOpenClawGateway(containerBin, instance.internalName);
        console.log(formatGatewayResult(gateway));
        console.log(`IP: ${ip ?? "pending"}`);
      } catch (error) {
        spinner.fail("Start failed.");
        throw error;
      }
    });
}

function instanceNotFoundMessage(name: string, available: string[]): string {
  if (available.length === 0) {
    return `Instance '${name}' not found. No clawbox instances exist yet.`;
  }

  return `Instance '${name}' not found. Available instances: ${available.join(", ")}`;
}
