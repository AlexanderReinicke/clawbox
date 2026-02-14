import chalk from "chalk";
import { Command } from "commander";
import inquirer from "inquirer";
import ora from "ora";
import { DEFAULT_RAM_GB, RAM_OPTIONS_GB } from "../lib/constants";
import { ensureDefaultImage } from "../lib/image";
import {
  createManagedInstance,
  ensureMountPathSafe,
  ensureUniqueInstanceName,
  listAllContainerNames,
  listManagedInstances,
  validateInstanceName
} from "../lib/instances";
import { evaluateRamPolicy, hostTotalRamGb, ramPolicyError, sumAllocatedRamGb } from "../lib/ram-policy";
import { ensureRuntimeRunning, requireContainerBinary } from "../lib/runtime";

interface CreateOptions {
  ram?: string;
  mount?: string;
  yes?: boolean;
}

export function registerCreateCommand(program: Command): void {
  program
    .command("create [name]")
    .description("Create a new VM instance")
    .option("--ram <gb>", "RAM allocation in GB (4, 5, 6, or custom >=4)")
    .option("--mount <path>", "Host folder to mount to /mnt/host")
    .option("-y, --yes", "Skip confirmation")
    .action(async (providedName: string | undefined, options: CreateOptions) => {
      const containerBin = await requireContainerBinary();
      await ensureRuntimeRunning(containerBin);

      const instances = await listManagedInstances(containerBin);
      const existingContainerNames = await listAllContainerNames(containerBin);

      const totalRamGb = hostTotalRamGb();
      const allocatedGb = sumAllocatedRamGb(instances, "all");

      const minimumRamGb = RAM_OPTIONS_GB[0];
      const minimumPolicy = evaluateRamPolicy(totalRamGb, allocatedGb, minimumRamGb);
      if (!minimumPolicy.allowed) {
        throw new Error(ramPolicyError(minimumPolicy));
      }

      const allowedRamOptions = RAM_OPTIONS_GB.filter((ram) => evaluateRamPolicy(totalRamGb, allocatedGb, ram).allowed);
      if (allowedRamOptions.length === 0) {
        const failed = evaluateRamPolicy(totalRamGb, allocatedGb, minimumRamGb);
        throw new Error(ramPolicyError(failed));
      }

      let selectedRam: number | undefined = parseRamOption(options.ram, minimumRamGb);
      if (typeof selectedRam === "number" && !evaluateRamPolicy(totalRamGb, allocatedGb, selectedRam).allowed) {
        const failed = evaluateRamPolicy(totalRamGb, allocatedGb, selectedRam);
        throw new Error(ramPolicyError(failed));
      }

      if (typeof selectedRam !== "number") {
        if (process.stdout.isTTY) {
          const choiceAnswer = await inquirer.prompt<{ ramChoice: string }>([
            {
              type: "list",
              name: "ramChoice",
              message: "Select RAM allocation:",
              choices: [
                ...allowedRamOptions.map((ram) => ({
                  name: `${ram} GB${ram === DEFAULT_RAM_GB ? " (default)" : ""}`,
                  value: String(ram)
                })),
                { name: "Custom", value: "custom" }
              ],
              default: allowedRamOptions.includes(DEFAULT_RAM_GB) ? String(DEFAULT_RAM_GB) : String(allowedRamOptions[0])
            }
          ]);
          if (choiceAnswer.ramChoice === "custom") {
            const customAnswer = await inquirer.prompt<{ customRam: string }>([
              {
                type: "input",
                name: "customRam",
                message: `Custom RAM in GB (integer, >=${minimumRamGb}):`,
                validate: (input) => {
                  try {
                    const candidate = parseRamOption(input, minimumRamGb);
                    if (typeof candidate !== "number") {
                      return `RAM is required (>=${minimumRamGb}).`;
                    }
                    const policy = evaluateRamPolicy(totalRamGb, allocatedGb, candidate);
                    if (!policy.allowed) {
                      return `Rejected by RAM policy: ${policy.remainingGb} GB would remain (< ${policy.reserveFloorGb} GB).`;
                    }
                    return true;
                  } catch (error) {
                    return error instanceof Error ? error.message : String(error);
                  }
                }
              }
            ]);
            selectedRam = parseRamOption(customAnswer.customRam, minimumRamGb);
          } else {
            selectedRam = Number(choiceAnswer.ramChoice);
          }
        } else {
          selectedRam = allowedRamOptions.includes(DEFAULT_RAM_GB) ? DEFAULT_RAM_GB : allowedRamOptions[0];
        }
      }

      if (typeof selectedRam !== "number") {
        throw new Error("Unable to resolve RAM allocation option.");
      }

      const policy = evaluateRamPolicy(totalRamGb, allocatedGb, selectedRam);
      if (!policy.allowed) {
        throw new Error(ramPolicyError(policy));
      }

      let mountPath = options.mount ? ensureMountPathSafe(options.mount) : undefined;
      if (!options.mount && process.stdout.isTTY) {
        const mountChoice = await inquirer.prompt<{ shouldMount: boolean }>([
          {
            type: "confirm",
            name: "shouldMount",
            message: "Mount a host folder at /mnt/host?",
            default: false
          }
        ]);

        if (mountChoice.shouldMount) {
          const mountPrompt = await inquirer.prompt<{ mountPath: string }>([
            {
              type: "input",
              name: "mountPath",
              message: "Host folder path:",
              validate: (input) => {
                try {
                  ensureMountPathSafe(input);
                  return true;
                } catch (error) {
                  return error instanceof Error ? error.message : String(error);
                }
              }
            }
          ]);
          mountPath = ensureMountPathSafe(mountPrompt.mountPath);
        }
      }

      let name = providedName;
      if (!name && process.stdout.isTTY) {
        const answer = await inquirer.prompt<{ name: string }>([
          {
            type: "input",
            name: "name",
            message: "Instance name:",
            validate: (input) => {
              const validationMessage = validateInstanceName(input);
              if (validationMessage) {
                return validationMessage;
              }
              try {
                ensureUniqueInstanceName(input, existingContainerNames);
                return true;
              } catch (error) {
                return error instanceof Error ? error.message : String(error);
              }
            }
          }
        ]);
        name = answer.name;
      }

      if (!name) {
        throw new Error("Instance name is required. Provide `clawbox create <name>` or run in interactive mode.");
      }

      const validationMessage = validateInstanceName(name);
      if (validationMessage) {
        throw new Error(validationMessage);
      }
      ensureUniqueInstanceName(name, existingContainerNames);

      console.log(chalk.cyan("Create summary"));
      console.log(`  Name: ${name}`);
      console.log(`  RAM: ${selectedRam} GB`);
      console.log(`  Mount: ${mountPath ?? "none"}`);
      console.log(`  Host total RAM: ${policy.totalGb} GB`);
      console.log(`  Currently allocated: ${policy.allocatedGb} GB`);
      console.log(`  Remaining after create: ${policy.remainingGb} GB`);

      if (!options.yes) {
        if (!process.stdout.isTTY) {
          throw new Error("Confirmation required. Re-run with --yes in non-interactive mode.");
        }
        const answer = await inquirer.prompt<{ proceed: boolean }>([
          {
            type: "confirm",
            name: "proceed",
            message: "Create this instance?",
            default: true
          }
        ]);
        if (!answer.proceed) {
          console.log("Cancelled.");
          return;
        }
      }

      await ensureDefaultImage(containerBin);

      const spinner = ora(`Creating instance '${name}'...`).start();
      try {
        await createManagedInstance(containerBin, {
          name,
          ramGb: selectedRam,
          mountPath
        });
        spinner.succeed(`Created instance '${name}'.`);
      } catch (error) {
        spinner.fail("Create failed.");
        throw error;
      }

      console.log(`Next: run ${chalk.bold(`clawbox start ${name}`)} then ${chalk.bold(`clawbox shell ${name}`)}.`);
    });
}

function parseRamOption(input: string | undefined, minimumRamGb: number): number | undefined {
  if (!input) {
    return undefined;
  }

  const trimmed = input.trim();
  if (!trimmed) {
    return undefined;
  }

  const numeric = Number(trimmed);
  if (!Number.isInteger(numeric)) {
    throw new Error("--ram must be an integer.");
  }
  if (numeric < minimumRamGb) {
    throw new Error(`--ram must be >= ${minimumRamGb}.`);
  }
  return numeric;
}
