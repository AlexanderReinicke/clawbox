import chalk from "chalk";
import { Command } from "commander";
import { registerAboutCommand } from "./commands/about";
import { registerCreateCommand } from "./commands/create";
import { registerDeleteCommand } from "./commands/delete";
import { registerDoctorCommand } from "./commands/doctor";
import { registerInspectCommand } from "./commands/inspect";
import { registerLsCommand } from "./commands/ls";
import { registerPauseCommand } from "./commands/pause";
import { registerShellCommand } from "./commands/shell";
import { registerStartCommand } from "./commands/start";
import { CLI_NAME } from "./lib/constants";
import { readPackageMeta } from "./lib/package";

const pkg = readPackageMeta();
const program = new Command();
const normalizedArgv = process.argv.map((arg) => (arg === "-v" ? "--version" : arg));

program
  .name(CLI_NAME)
  .description("Opinionated VM instance manager for Apple's container runtime")
  .version(pkg.version ?? "0.0.0", "--version", "output the version number");

registerAboutCommand(program);
registerDoctorCommand(program);
registerCreateCommand(program);
registerLsCommand(program);
registerStartCommand(program);
registerPauseCommand(program);
registerShellCommand(program);
registerDeleteCommand(program);
registerInspectCommand(program);

program.parseAsync(normalizedArgv).catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(chalk.red(message));
  process.exitCode = 1;
});
