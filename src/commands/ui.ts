import { Command } from "commander";
import { runUiSession } from "../services/ui-session";

const DEFAULT_LOCAL_PORT = 18789;

interface UiOptions {
  port?: string;
  yes?: boolean;
  open?: boolean;
}

export function registerUiCommand(program: Command): void {
  program
    .command("ui [name]")
    .description("Open OpenClaw Control UI on localhost with a built-in proxy")
    .option("-p, --port <port>", "Local port to bind on this Mac", String(DEFAULT_LOCAL_PORT))
    .option("-y, --yes", "Auto-start paused instances without prompting")
    .option("--no-open", "Do not open the browser automatically")
    .action(async (name: string | undefined, options: UiOptions) => {
      await runUiSession({
        name,
        port: options.port,
        yes: options.yes,
        open: options.open
      });
    });
}
