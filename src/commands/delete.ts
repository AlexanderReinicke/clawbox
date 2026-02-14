import inquirer from "inquirer";
import ora from "ora";
import { Command } from "commander";
import { getCommandContext } from "../lib/command-context";
import { CliError } from "../lib/errors";
import { deleteManagedInstance, listManagedInstances, pauseManagedInstance, requireInstanceByName } from "../lib/instances";

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
      const { containerBin } = await getCommandContext();

      const instances = await listManagedInstances(containerBin);
      const instance = requireInstanceByName(instances, name);

      if (!options.yes) {
        if (!process.stdout.isTTY) {
          throw new CliError({
            kind: "validation",
            message: "Delete confirmation requires TTY. Re-run with --yes --confirm-name <name>."
          });
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
          throw new CliError({
            kind: "validation",
            message: "Confirmation name mismatch. Delete aborted."
          });
        }
      } else if (options.confirmName !== name) {
        throw new CliError({
          kind: "validation",
          message: "Non-interactive delete requires --confirm-name to exactly match the instance name."
        });
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
