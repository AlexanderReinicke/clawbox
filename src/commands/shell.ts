import inquirer from "inquirer";
import ora from "ora";
import path from "node:path";
import { Command } from "commander";
import { getCommandContext } from "../lib/command-context";
import { DEFAULT_RAM_GB } from "../lib/constants";
import { runCommand, runInteractive } from "../lib/exec";
import { CliError } from "../lib/errors";
import { ensureOpenClawGateway, formatGatewayResult } from "../lib/gateway";
import { listManagedInstances, requireInstanceByName, startManagedInstance, waitForInstanceIp } from "../lib/instances";
import { evaluateRamPolicy, hostTotalRamGb, ramPolicyError, sumAllocatedRamGb } from "../lib/ram-policy";

interface ShellOptions {
  yes?: boolean;
  newTerminal?: boolean;
}

export function registerShellCommand(program: Command): void {
  program
    .command("shell <name>")
    .description("Open an interactive shell inside a running instance")
    .option("-y, --yes", "Auto-start paused instances without prompting")
    .option("-n, --new-terminal", "Open the shell in a new Terminal.app window")
    .action(async (name: string, options: ShellOptions) => {
      if (options.newTerminal) {
        await openInNewTerminal(name, Boolean(options.yes));
        console.log(`Opened a new Terminal window for '${name}'.`);
        return;
      }

      const { containerBin } = await getCommandContext({ ensurePowerDaemon: true });

      const instances = await listManagedInstances(containerBin);
      const instance = requireInstanceByName(instances, name);

      if (instance.status !== "running") {
        let shouldStart = Boolean(options.yes);
        if (!options.yes) {
          if (!process.stdout.isTTY) {
            throw new CliError({
              kind: "validation",
              message: `Instance '${name}' is paused. Re-run with --yes to auto-start in non-interactive mode.`
            });
          }
          const answer = await inquirer.prompt<{ startNow: boolean }>([
            {
              type: "confirm",
              name: "startNow",
              message: `Instance '${name}' is paused. Start it now?`,
              default: true
            }
          ]);
          shouldStart = answer.startNow;
        }

        if (!shouldStart) {
          console.log("Cancelled.");
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

        const spinner = ora(`Starting '${name}' before shell attach...`).start();
        try {
          await startManagedInstance(containerBin, instance.internalName);
          await waitForInstanceIp(containerBin, instance.internalName);
          spinner.succeed(`Started '${name}'.`);
        } catch (error) {
          spinner.fail("Start failed.");
          throw error;
        }
      }

      const gateway = await ensureOpenClawGateway(containerBin, instance.internalName);
      if (gateway.status === "error") {
        console.log(formatGatewayResult(gateway));
      }

      console.log(`Control UI tip: run 'clawbox ui ${name}' from your Mac for localhost-safe access.`);
      const shellPath = await resolvePreferredShell(containerBin, instance.internalName);
      console.log(`Attaching to '${name}'. Use Ctrl+D or 'exit' to return.`);
      await runInteractive(containerBin, ["exec", "-i", "-t", instance.internalName, shellPath]);
    });
}

async function openInNewTerminal(name: string, yes: boolean): Promise<void> {
  if (process.platform !== "darwin") {
    throw new CliError({
      kind: "validation",
      message: "--new-terminal is only available on macOS."
    });
  }

  const entrypoint = resolveCliEntrypoint();
  const args = [process.execPath, entrypoint, "shell", name];
  if (yes) {
    args.push("--yes");
  }
  const command = args.map(shellQuote).join(" ");
  const script = `tell application "Terminal" to do script "${escapeForAppleScript(command)}"`;

  await runCommand("osascript", ["-e", 'tell application "Terminal" to activate', "-e", script], {
    timeoutMs: 10_000
  });
}

function resolveCliEntrypoint(): string {
  const entrypoint = process.argv[1];
  if (!entrypoint) {
    throw new CliError({
      kind: "runtime",
      message: "Unable to resolve CLI entrypoint for --new-terminal."
    });
  }
  return path.isAbsolute(entrypoint) ? entrypoint : path.resolve(process.cwd(), entrypoint);
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function escapeForAppleScript(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

async function resolvePreferredShell(containerBin: string, internalName: string): Promise<string> {
  const bashCheck = await runCommand(
    containerBin,
    ["exec", "-i", internalName, "/bin/sh", "-lc", "test -x /bin/bash"],
    { allowNonZeroExit: true, timeoutMs: 10_000 }
  );
  return bashCheck.exitCode === 0 ? "/bin/bash" : "/bin/sh";
}
