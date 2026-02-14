import ora from "ora";
import { Command } from "commander";
import { listManagedInstances, pauseManagedInstance } from "../lib/instances";
import { ensureRuntimeRunning, requireContainerBinary } from "../lib/runtime";

export function registerPauseCommand(program: Command): void {
  program
    .command("pause <name>")
    .description("Pause a running instance")
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

      if (instance.status !== "running") {
        console.log(`Instance '${name}' is already paused.`);
        return;
      }

      const spinner = ora(`Pausing '${name}'...`).start();
      try {
        await pauseManagedInstance(containerBin, instance.internalName);
        spinner.succeed(`Paused '${name}'.`);
      } catch (error) {
        spinner.fail("Pause failed.");
        throw error;
      }

      console.log("Filesystem is preserved. Resume anytime with `clawbox start <name>`. ");
    });
}
