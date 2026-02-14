import { spawn, type ChildProcess } from "node:child_process";
import inquirer from "inquirer";
import net from "node:net";
import ora from "ora";
import { getCommandContext } from "../lib/command-context";
import { DEFAULT_RAM_GB } from "../lib/constants";
import { runCommand } from "../lib/exec";
import { CliError } from "../lib/errors";
import { ensureOpenClawGateway } from "../lib/gateway";
import { listManagedInstances, requireInstanceByName, startManagedInstance, waitForInstanceIp } from "../lib/instances";
import { evaluateRamPolicy, hostTotalRamGb, ramPolicyError, sumAllocatedRamGb } from "../lib/ram-policy";

const REMOTE_GATEWAY_PORT = 18789;
const DEFAULT_LOCAL_PORT = 18789;

export interface UiSessionOptions {
  name?: string;
  port?: string;
  yes?: boolean;
  open?: boolean;
}

interface BridgeSpec {
  label: string;
  args: string[];
}

export async function runUiSession(options: UiSessionOptions): Promise<void> {
  const localPort = parsePort(options.port);
  const { containerBin } = await getCommandContext({ ensurePowerDaemon: true });

  const instances = await listManagedInstances(containerBin);
  const name = await resolveInstanceName(options.name, instances.map((item) => item.name));
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

    const spinner = ora(`Starting '${name}' for Control UI...`).start();
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
    throw new CliError({
      kind: "runtime",
      message: gateway.message,
      detail: gateway.detail
    });
  }

  const bridgeSpec = await resolveBridgeSpec(containerBin, instance.internalName);
  const { server, activeBridges, stop } = await startLocalProxy(containerBin, instance.internalName, localPort, bridgeSpec);

  const url = `http://127.0.0.1:${localPort}/`;
  if (options.open !== false) {
    await runCommand("open", [url], { allowNonZeroExit: true, timeoutMs: 10_000 });
  }

  console.log(`Control UI is available at ${url}`);
  console.log(`Proxy mode: ${bridgeSpec.label}`);
  console.log("Press Ctrl+C to stop the proxy.");

  await waitForShutdownSignal(async () => {
    await stop();
    for (const child of activeBridges) {
      child.kill("SIGTERM");
    }
  });

  server.unref();
}

async function resolveInstanceName(providedName: string | undefined, availableNames: string[]): Promise<string> {
  if (providedName) {
    return providedName;
  }

  if (availableNames.length === 0) {
    throw new CliError({
      kind: "not_found",
      message: "No clawbox instances found.",
      hint: "Create one first with `clawbox create <name>`."
    });
  }

  if (!process.stdout.isTTY) {
    throw new CliError({
      kind: "validation",
      message: "Missing required argument 'name' in non-interactive mode.",
      hint: "Run `clawbox ui <name>`."
    });
  }

  const answer = await inquirer.prompt<{ name: string }>([
    {
      type: "list",
      name: "name",
      message: "Select instance for Control UI:",
      choices: availableNames
    }
  ]);
  return answer.name;
}

function parsePort(value: string | undefined): number {
  const numeric = value ? Number(value) : DEFAULT_LOCAL_PORT;
  if (!Number.isInteger(numeric) || numeric < 1 || numeric > 65535) {
    throw new CliError({
      kind: "validation",
      message: "--port must be an integer between 1 and 65535."
    });
  }
  return numeric;
}

async function resolveBridgeSpec(containerBin: string, internalName: string): Promise<BridgeSpec> {
  const pythonCheck = await runCommand(
    containerBin,
    ["exec", "-i", internalName, "/bin/sh", "-lc", "command -v python3 >/dev/null 2>&1"],
    { allowNonZeroExit: true, timeoutMs: 10_000 }
  );
  if (pythonCheck.exitCode === 0) {
    return {
      label: "python3 tcp bridge",
      args: ["python3", "-u", "-c", pythonBridgeScript(REMOTE_GATEWAY_PORT)]
    };
  }

  const bashCheck = await runCommand(
    containerBin,
    ["exec", "-i", internalName, "/bin/sh", "-lc", "test -x /bin/bash"],
    { allowNonZeroExit: true, timeoutMs: 10_000 }
  );
  if (bashCheck.exitCode === 0) {
    return {
      label: "bash /dev/tcp bridge",
      args: ["/bin/bash", "-lc", `exec 3<>/dev/tcp/127.0.0.1/${REMOTE_GATEWAY_PORT}; cat <&3 & cat >&3`]
    };
  }

  throw new CliError({
    kind: "runtime",
    message: "Unable to build a local proxy bridge: neither python3 nor /bin/bash is available in the instance."
  });
}

function pythonBridgeScript(port: number): string {
  return [
    "import socket",
    "import sys",
    "import threading",
    `sock = socket.create_connection(('127.0.0.1', ${port}), timeout=10)`,
    "",
    "def stdin_to_sock():",
    "  try:",
    "    while True:",
    "      data = sys.stdin.buffer.read1(65536)",
    "      if not data:",
    "        break",
    "      sock.sendall(data)",
    "  except Exception:",
    "    pass",
    "  finally:",
    "    try:",
    "      sock.shutdown(socket.SHUT_WR)",
    "    except Exception:",
    "      pass",
    "",
    "threading.Thread(target=stdin_to_sock, daemon=True).start()",
    "try:",
    "  while True:",
    "    chunk = sock.recv(65536)",
    "    if not chunk:",
    "      break",
    "    sys.stdout.buffer.write(chunk)",
    "    sys.stdout.buffer.flush()",
    "finally:",
    "  try:",
    "    sock.close()",
    "  except Exception:",
    "    pass"
  ].join("\n");
}

async function startLocalProxy(
  containerBin: string,
  internalName: string,
  localPort: number,
  bridgeSpec: BridgeSpec
): Promise<{
  server: net.Server;
  activeBridges: Set<ChildProcess>;
  stop: () => Promise<void>;
}> {
  const activeBridges = new Set<ChildProcess>();
  const server = net.createServer((socket) => {
    const bridge = spawn(containerBin, ["exec", "-i", internalName, ...bridgeSpec.args], {
      stdio: ["pipe", "pipe", "pipe"]
    });
    activeBridges.add(bridge);

    bridge.stderr?.on("data", () => {
      // Ignore per-connection stderr noise; failures are surfaced by socket close.
    });

    socket.on("error", () => {
      bridge.kill("SIGTERM");
    });

    bridge.on("error", () => {
      if (!socket.destroyed) {
        socket.destroy();
      }
    });

    bridge.on("close", () => {
      activeBridges.delete(bridge);
      if (!socket.destroyed) {
        socket.end();
      }
    });

    socket.pipe(bridge.stdin!);
    bridge.stdout?.pipe(socket);
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(localPort, "127.0.0.1", () => resolve());
  });

  return {
    server,
    activeBridges,
    stop: async () => {
      await new Promise<void>((resolve) => {
        server.close(() => resolve());
      });
    }
  };
}

async function waitForShutdownSignal(onShutdown: () => Promise<void>): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    let shuttingDown = false;
    const handle = async () => {
      if (shuttingDown) {
        return;
      }
      shuttingDown = true;
      process.off("SIGINT", handle);
      process.off("SIGTERM", handle);
      try {
        await onShutdown();
        resolve();
      } catch (error) {
        reject(error);
      }
    };

    process.on("SIGINT", handle);
    process.on("SIGTERM", handle);
  });
}
