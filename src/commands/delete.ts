import inquirer from "inquirer";
import ora from "ora";
import { Command } from "commander";
import { deleteManagedInstance, listManagedInstances, pauseManagedInstance } from "../lib/instances";
import { ensureRuntimeRunning, requireContainerBinary } from "../lib/runtime";

interface DeleteOptions {
  yes?: boolean;
  confirmName?: string;
}

export function registerDeleteCommand(program: Command): void {
  program
    .command("delete <name>")
    .description("Permanently delete an instance and its filesystem")
    .option("-y, --yes", "Skip interactive confirmation")
    .option("--confirm-name <name>", "Name confirmation for non-interactive delete")
    .action(async (name: string, options: DeleteOptions) => {
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

      if (!options.yes) {
        if (!process.stdout.isTTY) {
          throw new Error("Delete confirmation requires TTY. Re-run with --yes --confirm-name <name>.");
        }

        const confirm = await inquirer.prompt<{ proceed: boolean }>([
          {
            type: "confirm",
            name: "proceed",
            message: `Delete '${name}' permanently?`,
            default: false
          }
        ]);
        if (!confirm.proceed) {
          console.log("Cancelled.");
          return;
        }

        const typed = await inquirer.prompt<{ typedName: string }>([
          {
            type: "input",
            name: "typedName",
            message: `Type '${name}' to confirm:`
          }
        ]);

        if (typed.typedName !== name) {
          throw new Error("Confirmation name mismatch. Delete aborted.");
        }
      } else if (options.confirmName !== name) {
        throw new Error("Non-interactive delete requires --confirm-name to exactly match the instance name.");
      }

      const spinner = ora(`Deleting '${name}'...`).start();
      try {
        if (instance.status === "running") {
          await pauseManagedInstance(containerBin, instance.internalName);
        }
        await deleteManagedInstance(containerBin, instance.internalName);
        spinner.succeed(`Deleted '${name}'.`);
      } catch (error) {
        spinner.fail("Delete failed.");
        throw error;
      }
    });
}
