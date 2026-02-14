import { spawn } from "node:child_process";

export interface RunOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
  allowNonZeroExit?: boolean;
}

export interface RunResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export class CommandError extends Error {
  command: string;
  exitCode: number;
  stdout: string;
  stderr: string;

  constructor(command: string, exitCode: number, stdout: string, stderr: string) {
    super(`Command failed (${exitCode}): ${command}`);
    this.command = command;
    this.exitCode = exitCode;
    this.stdout = stdout;
    this.stderr = stderr;
  }
}

export async function runCommand(command: string, args: string[] = [], options: RunOptions = {}): Promise<RunResult> {
  const timeoutMs = options.timeoutMs ?? 60_000;
  const env = options.env ? { ...process.env, ...options.env } : process.env;

  return await new Promise<RunResult>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    let settled = false;

    const timeoutHandle = setTimeout(() => {
      child.kill("SIGTERM");
      if (!settled) {
        settled = true;
        reject(new Error(`Command timed out after ${timeoutMs}ms: ${formatCommand(command, args)}`));
      }
    }, timeoutMs);

    child.stdout?.on("data", (chunk: Buffer | string) => {
      stdout += chunk.toString();
    });

    child.stderr?.on("data", (chunk: Buffer | string) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      clearTimeout(timeoutHandle);
      if (!settled) {
        settled = true;
        reject(error);
      }
    });

    child.on("close", (code) => {
      clearTimeout(timeoutHandle);
      const exitCode = typeof code === "number" ? code : 1;
      if (exitCode !== 0 && !options.allowNonZeroExit) {
        if (!settled) {
          settled = true;
          reject(new CommandError(formatCommand(command, args), exitCode, stdout.trim(), stderr.trim()));
        }
        return;
      }
      if (!settled) {
        settled = true;
        resolve({ stdout: stdout.trim(), stderr: stderr.trim(), exitCode });
      }
    });
  });
}

export async function runInteractive(command: string, args: string[] = [], options: Omit<RunOptions, "allowNonZeroExit"> = {}): Promise<number> {
  const timeoutMs = options.timeoutMs ?? 0;
  const env = options.env ? { ...process.env, ...options.env } : process.env;

  return await new Promise<number>((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env,
      stdio: "inherit"
    });

    let timeoutHandle: NodeJS.Timeout | undefined;
    if (timeoutMs > 0) {
      timeoutHandle = setTimeout(() => {
        child.kill("SIGTERM");
        reject(new Error(`Command timed out after ${timeoutMs}ms: ${formatCommand(command, args)}`));
      }, timeoutMs);
    }

    child.on("error", (error) => {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle);
      }
      reject(error);
    });

    child.on("close", (code) => {
      if (timeoutHandle) {
        clearTimeout(timeoutHandle);
      }
      resolve(typeof code === "number" ? code : 1);
    });
  });
}

export function formatCommand(command: string, args: string[]): string {
  return [command, ...args].join(" ");
}
