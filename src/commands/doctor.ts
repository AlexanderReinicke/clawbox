import chalk from "chalk";
import { Command } from "commander";
import { runPreflight } from "../lib/preflight";

export function registerDoctorCommand(program: Command): void {
  program
    .command("doctor")
    .description("Run first-install prerequisite checks")
    .action(async () => {
      const report = await runPreflight();
      const suggestedCommands = new Set<string>();

      for (const check of report.checks) {
        const symbol = check.ok ? chalk.green("✔") : chalk.red("✖");
        console.log(`${symbol} ${check.message}`);
        if (!check.ok && check.fix) {
          console.log(`  fix: ${check.fix}`);
        }
        if (!check.ok && check.suggestedCommands && check.suggestedCommands.length > 0) {
          for (const command of check.suggestedCommands) {
            console.log(`  please run: ${chalk.bold(command)}`);
            suggestedCommands.add(command);
          }
        }
      }

      if (!report.ok) {
        if (suggestedCommands.size > 0) {
          console.log("");
          console.log(chalk.yellow("Action required: run the command(s) above, then re-run `clawbox doctor`."));
        }
        process.exitCode = 1;
        throw new Error("Preflight failed.");
      }
    });
}
