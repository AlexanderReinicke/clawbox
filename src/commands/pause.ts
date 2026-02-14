import ora from "ora";
import { Command } from "commander";
import { getCommandContext } from "../lib/command-context";
import { listManagedInstances, pauseManagedInstance, requireInstanceByName } from "../lib/instances";

export function registerPauseCommand(program: Command): void {
  program
    .command("pause <name>")
    .description("Pause a running instance")
    .action(async (name: string) => {
      const { containerBin } = await getCommandContext();

      const instances = await listManagedInstances(containerBin);
      const instance = requireInstanceByName(instances, name);

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
