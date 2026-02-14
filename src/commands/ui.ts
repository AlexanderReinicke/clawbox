import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import inquirer from "inquirer";
import ora from "ora";
import { Command } from "commander";
import { DEFAULT_RAM_GB } from "../lib/constants";
import { runCommand } from "../lib/exec";
import { ensureOpenClawGateway, formatGatewayResult } from "../lib/gateway";
import { listManagedInstances, startManagedInstance, waitForInstanceIp } from "../lib/instances";
import { ensurePowerDaemonRunning } from "../lib/power";
import { evaluateRamPolicy, hostTotalRamGb, ramPolicyError, sumAllocatedRamGb } from "../lib/ram-policy";
import { ensureRuntimeRunning, requireContainerBinary } from "../lib/runtime";

const REMOTE_GATEWAY_PORT = 18789;
const DEFAULT_LOCAL_PORT = 18789;

interface UiOptions {
  port?: string;
  yes?: boolean;
  open?: boolean;
}

interface BridgeSpec {
  label: string;
  args: string[];
}

export function registerUiCommand(program: Command): void {
  program
    .command("ui <name>")
    .description("Open OpenClaw Control UI on localhost with a built-in proxy")
    .option("-p, --port <port>", "Local port to bind on this Mac", String(DEFAULT_LOCAL_PORT))
    .option("-y, --yes", "Auto-start paused instances without prompting")
    .option("--no-open", "Do not open the browser automatically")
    .action(async (name: string, options: UiOptions) => {
      const localPort = parsePort(options.port);
      const containerBin = await requireContainerBinary();
      await ensureRuntimeRunning(containerBin);
      await ensurePowerDaemonRunning();

      const instances = await listManagedInstances(containerBin);
      const instance = instances.find((item) => item.name === name);
      if (!instance) {
        const names = instances.map((item) => item.name);
        throw new Error(names.length > 0
          ? `Instance '${name}' not found. Available instances: ${names.join(", ")}`
          : `Instance '${name}' not found. No clawbox instances exist yet.`);
      }

      if (instance.status !== "running") {
        let shouldStart = Boolean(options.yes);
        if (!options.yes) {
          if (!process.stdout.isTTY) {
            throw new Error(`Instance '${name}' is paused. Re-run with --yes to auto-start in non-interactive mode.`);
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
          throw new Error(ramPolicyError(policy));
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
        throw new Error(formatGatewayResult(gateway));
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
    });
}

function parsePort(value: string | undefined): number {
  const numeric = value ? Number(value) : DEFAULT_LOCAL_PORT;
  if (!Number.isInteger(numeric) || numeric < 1 || numeric > 65535) {
    throw new Error("--port must be an integer between 1 and 65535.");
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

  throw new Error("Unable to build a local proxy bridge: neither python3 nor /bin/bash is available in the instance.");
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
