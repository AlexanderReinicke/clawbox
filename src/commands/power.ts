import inquirer from "inquirer";
import { Command } from "commander";
import { getCommandContext } from "../lib/command-context";
import { listManagedInstances, requireInstanceByName } from "../lib/instances";
import { setKeepAwakePreference } from "../lib/instance-preferences";
import { CliError } from "../lib/errors";

interface PowerOptions {
  keepAwake?: boolean;
  allowSleep?: boolean;
}

export function registerPowerCommand(program: Command): void {
  program
    .command("power <name>")
    .description("Set host sleep policy for a VM")
    .option("--keep-awake", "Prevent Mac idle sleep while this VM is running (uses more battery)")
    .option("--allow-sleep", "Allow normal Mac sleep while this VM runs (lower battery use)")
    .action(async (name: string, options: PowerOptions) => {
      if (options.keepAwake && options.allowSleep) {
        throw new CliError({
          kind: "validation",
          message: "Choose either --keep-awake or --allow-sleep, not both."
        });
      }

      const { containerBin } = await getCommandContext({ ensurePowerDaemon: true });

      const instances = await listManagedInstances(containerBin);
      const instance = requireInstanceByName(instances, name);

      const keepAwake = await resolveTargetPolicy(options, instance.keepAwake !== false, name);
      await setKeepAwakePreference(instance.internalName, keepAwake);

      console.log(
        keepAwake
          ? `Updated '${name}': host sleep policy is now keep-awake (uses more battery).`
          : `Updated '${name}': host sleep policy is now normal (Mac sleep allowed).`
      );
    });
}

async function resolveTargetPolicy(options: PowerOptions, currentKeepAwake: boolean, name: string): Promise<boolean> {
  if (options.keepAwake) {
    return true;
  }
  if (options.allowSleep) {
    return false;
  }

  if (!process.stdout.isTTY) {
    throw new CliError({
      kind: "validation",
      message: `Specify --keep-awake or --allow-sleep in non-interactive mode for instance '${name}'.`
    });
  }

  const answer = await inquirer.prompt<{ keepAwake: boolean }>([
    {
      type: "list",
      name: "keepAwake",
      message: `Host sleep policy for '${name}':`,
      choices: [
        { name: "Keep awake while VM runs (more battery)", value: true },
        { name: "Allow normal Mac sleep (less battery)", value: false }
      ],
      default: currentKeepAwake
    }
  ]);
  return answer.keepAwake;
}
