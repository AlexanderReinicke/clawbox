import ora from "ora";
import { Command } from "commander";
import { getCommandContext } from "../lib/command-context";
import { DEFAULT_RAM_GB } from "../lib/constants";
import { ensureOpenClawGateway, formatGatewayResult } from "../lib/gateway";
import {
  listManagedInstances,
  requireInstanceByName,
  startManagedInstance,
  waitForInstanceIp
} from "../lib/instances";
import { evaluateRamPolicy, hostTotalRamGb, ramPolicyError, sumAllocatedRamGb } from "../lib/ram-policy";
import { CliError } from "../lib/errors";

export function registerStartCommand(program: Command): void {
  program
    .command("start <name>")
    .description("Start a paused instance")
    .action(async (name: string) => {
      const { containerBin } = await getCommandContext({ ensurePowerDaemon: true });

      const instances = await listManagedInstances(containerBin);
      const instance = requireInstanceByName(instances, name);

      if (instance.status === "running") {
        console.log(`Instance '${name}' is already running.`);
        const gateway = await ensureOpenClawGateway(containerBin, instance.internalName);
        if (gateway.status === "error") {
          console.log(formatGatewayResult(gateway));
        }
        if (instance.ip) {
          console.log(`IP: ${instance.ip}`);
        }
        console.log(`Control UI: run 'clawbox ui ${name}' for localhost-safe access from your Mac.`);
        return;
      }

      const totalRamGb = hostTotalRamGb();
      const allocatedRunningGb = sumAllocatedRamGb(instances, "running", instance.internalName);
      const requestedGb = instance.ramGb ?? DEFAULT_RAM_GB;
      const policy = evaluateRamPolicy(totalRamGb, allocatedRunningGb, requestedGb);
      if (!policy.allowed) {
        throw new CliError({
          kind: "validation",
          message: ramPolicyError(policy)
        });
      }

      const spinner = ora(`Starting '${name}'...`).start();
      try {
        await startManagedInstance(containerBin, instance.internalName);
        const ip = await waitForInstanceIp(containerBin, instance.internalName);
        spinner.succeed(`Started '${name}'.`);
        const gateway = await ensureOpenClawGateway(containerBin, instance.internalName);
        if (gateway.status === "error") {
          console.log(formatGatewayResult(gateway));
        }
        console.log(`IP: ${ip ?? "pending"}`);
        console.log(`Control UI: run 'clawbox ui ${name}' for localhost-safe access from your Mac.`);
      } catch (error) {
        spinner.fail("Start failed.");
        throw error;
      }
    });
}
