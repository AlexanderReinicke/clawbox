import { Command } from "commander";
import { listManagedInstances } from "../lib/instances";
import { ensureRuntimeRunning, requireContainerBinary } from "../lib/runtime";
import { formatGb } from "../lib/utils";

export function registerInspectCommand(program: Command): void {
  program
    .command("inspect <name>")
    .description("Show detailed info about an instance")
    .action(async (name: string) => {
      const containerBin = await requireContainerBinary();
      await ensureRuntimeRunning(containerBin);

      const instances = await listManagedInstances(containerBin);
      const instance = instances.find((item) => item.name === name);

      if (!instance) {
        const names = instances.map((item) => item.name);
        throw new Error(names.length > 0
          ? `Instance '${name}' not found. Available instances: ${names.join(", ")}`
          : `Instance '${name}' not found. No clawbox instances exist yet.`);
      }

      console.log(`name: ${instance.name}`);
      console.log(`internal name: ${instance.internalName}`);
      console.log(`status: ${instance.status}`);
      console.log(`ip: ${instance.ip ?? "-"}`);
      console.log(`ram: ${formatGb(instance.ramGb)}`);
      console.log(`mount: ${instance.mountPath ?? "-"}`);
      console.log(`created: ${instance.createdAt ? instance.createdAt.toISOString() : "-"}`);
      console.log(`started: ${instance.startedAt ? instance.startedAt.toISOString() : "-"}`);
      console.log(`uptime: ${computeUptime(instance.startedAt, instance.status)}`);
    });
}

function computeUptime(startedAt: Date | undefined, status: string): string {
  if (!startedAt || status !== "running") {
    return "-";
  }

  const seconds = Math.max(0, Math.floor((Date.now() - startedAt.getTime()) / 1000));
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);

  if (days > 0) {
    return `${days}d ${hours}h ${minutes}m`;
  }
  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  return `${minutes}m`;
}
