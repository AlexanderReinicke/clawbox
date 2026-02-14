import chalk from "chalk";
import { runCommand } from "./exec";

const GATEWAY_PORT = 18789;
const GATEWAY_LOG_PATH = "/home/agent/OpenClawProject/logs/gateway.log";

export interface GatewayEnsureResult {
  status: "ready" | "pending" | "skipped" | "error";
  message: string;
  detail?: string;
}

export async function ensureOpenClawGateway(
  containerBin: string,
  internalName: string
): Promise<GatewayEnsureResult> {
  const hasOpenClaw = await commandExists(containerBin, internalName, "openclaw");
  if (!hasOpenClaw) {
    await ensureGatewayBootstrapWatcher(containerBin, internalName);
    return {
      status: "pending",
      message: "OpenClaw not installed yet. Gateway bootstrap watcher is armed and will auto-start after install."
    };
  }

  await execShell(containerBin, internalName, "mkdir -p /home/agent/OpenClawProject/logs", false);

  const alreadyHealthy = await isGatewayHealthy(containerBin, internalName);
  if (alreadyHealthy) {
    return {
      status: "ready",
      message: "OpenClaw gateway already healthy."
    };
  }

  const hasGatewayProcess = await isGatewayProcessRunning(containerBin, internalName);
  if (hasGatewayProcess) {
    await stopGatewayProcesses(containerBin, internalName);
  }

  const started = await startGateway(containerBin, internalName);
  if (!started) {
    return {
      status: "error",
      message: "Failed to launch OpenClaw gateway process.",
      detail: await readGatewayLogTail(containerBin, internalName)
    };
  }

  const healthyAfterStart = await waitForGatewayHealth(containerBin, internalName, 25_000);
  if (healthyAfterStart) {
    return {
      status: "ready",
      message: `OpenClaw gateway is ready on ws://127.0.0.1:${GATEWAY_PORT}.`
    };
  }

  return {
    status: "error",
    message: "OpenClaw gateway did not become healthy in time.",
    detail: await readGatewayLogTail(containerBin, internalName)
  };
}

export function formatGatewayResult(result: GatewayEnsureResult): string {
  if (result.status === "ready") {
    return chalk.green(result.message);
  }
  if (result.status === "pending") {
    return chalk.cyan(result.message);
  }
  if (result.status === "skipped") {
    return chalk.yellow(result.message);
  }

  let message = chalk.red(result.message);
  if (result.detail) {
    message += `\n${chalk.dim("gateway log tail:")}\n${result.detail}`;
  }
  return message;
}

async function commandExists(containerBin: string, internalName: string, command: string): Promise<boolean> {
  const result = await execShell(containerBin, internalName, `command -v ${shellQuote(command)} >/dev/null 2>&1`, true);
  return result.exitCode === 0;
}

async function isGatewayHealthy(containerBin: string, internalName: string): Promise<boolean> {
  const probe = await execShell(
    containerBin,
    internalName,
    `curl -fsS --max-time 2 http://127.0.0.1:${GATEWAY_PORT} >/dev/null 2>&1`,
    true
  );
  return probe.exitCode === 0;
}

async function isGatewayProcessRunning(containerBin: string, internalName: string): Promise<boolean> {
  const check = await execShell(
    containerBin,
    internalName,
    "ps -eo comm= | grep -Fxq openclaw-gateway",
    true
  );
  return check.exitCode === 0;
}

async function stopGatewayProcesses(containerBin: string, internalName: string): Promise<void> {
  await execShell(
    containerBin,
    internalName,
    "for pid in $(ps -eo pid=,comm= | awk '$2==\"openclaw-gateway\" {print $1}'); do kill \"$pid\" >/dev/null 2>&1 || true; done",
    true
  );
}

async function startGateway(containerBin: string, internalName: string): Promise<boolean> {
  const start = await execShell(
    containerBin,
    internalName,
    `nohup openclaw gateway --bind loopback >${shellQuote(GATEWAY_LOG_PATH)} 2>&1 &`,
    true
  );
  return start.exitCode === 0;
}

async function waitForGatewayHealth(containerBin: string, internalName: string, timeoutMs: number): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await isGatewayHealthy(containerBin, internalName)) {
      return true;
    }
    await sleep(1000);
  }
  return false;
}

async function readGatewayLogTail(containerBin: string, internalName: string): Promise<string> {
  const log = await execShell(
    containerBin,
    internalName,
    `tail -n 80 ${shellQuote(GATEWAY_LOG_PATH)} 2>/dev/null || (latest=$(ls -1t /tmp/openclaw/openclaw-*.log 2>/dev/null | head -n 1); [ -n "$latest" ] && tail -n 80 "$latest" 2>/dev/null) || echo "<no gateway log found>"`,
    true
  );
  return log.stdout || log.stderr || "<no log output>";
}

async function ensureGatewayBootstrapWatcher(containerBin: string, internalName: string): Promise<void> {
  const script = `
pid_file="/tmp/clawbox-gateway-bootstrap.pid"
if [ -f "$pid_file" ]; then
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
fi

nohup /bin/bash -lc '
for _ in $(seq 1 360); do
  if command -v openclaw >/dev/null 2>&1; then
    mkdir -p /home/agent/OpenClawProject/logs
    if ! curl -fsS --max-time 2 http://127.0.0.1:${GATEWAY_PORT} >/dev/null 2>&1; then
      nohup openclaw gateway --bind loopback >/home/agent/OpenClawProject/logs/gateway.log 2>&1 &
      sleep 2
    fi
    if curl -fsS --max-time 2 http://127.0.0.1:${GATEWAY_PORT} >/dev/null 2>&1; then
      exit 0
    fi
  fi
  sleep 5
done
exit 0
' >/tmp/clawbox-gateway-bootstrap.log 2>&1 &
echo $! > "$pid_file"
`;

  await execShell(containerBin, internalName, script, true);
}

async function execShell(
  containerBin: string,
  internalName: string,
  script: string,
  allowNonZeroExit: boolean
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  return await runCommand(
    containerBin,
    ["exec", "-i", internalName, "/bin/bash", "-lc", script],
    { timeoutMs: 60_000, allowNonZeroExit }
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}
