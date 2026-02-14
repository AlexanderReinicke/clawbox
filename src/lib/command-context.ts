import { ensurePowerDaemonRunning } from "./power";
import { ensureRuntimeRunning, requireContainerBinary } from "./runtime";
import { CliError } from "./errors";

export interface CommandContext {
  containerBin: string;
}

export interface CommandContextOptions {
  ensurePowerDaemon?: boolean;
}

export async function getCommandContext(options: CommandContextOptions = {}): Promise<CommandContext> {
  let containerBin: string;
  try {
    containerBin = await requireContainerBinary();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new CliError({
      kind: "dependency",
      message,
      hint: "Install the Apple container CLI, then run `container system start`."
    });
  }

  try {
    await ensureRuntimeRunning(containerBin);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new CliError({
      kind: "dependency",
      message,
      hint: "Run `container system start` and retry."
    });
  }

  if (options.ensurePowerDaemon) {
    await ensurePowerDaemonRunning();
  }
  return { containerBin };
}
