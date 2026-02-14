import { hostTotalRamGb } from "./ram-policy";
import { getContainerVersion, getHostCompatibility, getRuntimeStatus, resolveContainerBinary } from "./runtime";

export interface PreflightCheck {
  key: string;
  ok: boolean;
  message: string;
  fix?: string;
  suggestedCommands?: string[];
}

export interface PreflightReport {
  checks: PreflightCheck[];
  ok: boolean;
}

export async function runPreflight(): Promise<PreflightReport> {
  const checks: PreflightCheck[] = [];

  const compatibility = getHostCompatibility();
  checks.push({
    key: "host",
    ok: compatibility.supported,
    message: compatibility.supported
      ? `Host platform is supported (${compatibility.os}/${compatibility.arch})`
      : compatibility.reason ?? "Unsupported host platform",
    fix: compatibility.supported ? undefined : "Use macOS on Apple Silicon."
  });

  const nodeMajor = Number(process.versions.node.split(".")[0] ?? "0");
  checks.push({
    key: "node",
    ok: Number.isFinite(nodeMajor) && nodeMajor >= 18,
    message: `Node.js ${process.version}`,
    fix: nodeMajor >= 18 ? undefined : "Install Node.js 18 or newer.",
    suggestedCommands: nodeMajor >= 18 ? undefined : ["brew install node"]
  });

  const totalRamGb = hostTotalRamGb();
  checks.push({
    key: "ram",
    ok: totalRamGb >= 16,
    message: `Host RAM: ${totalRamGb} GB`,
    fix: totalRamGb >= 16 ? undefined : "Use a host with at least 16 GB RAM."
  });

  const containerBin = await resolveContainerBinary();
  if (!containerBin) {
    checks.push({
      key: "container-bin",
      ok: false,
      message: "Apple container CLI not found.",
      fix: "Install Apple's container CLI, then start the runtime.",
      suggestedCommands: [
        "curl -fL -o /tmp/container-installer-signed.pkg https://github.com/apple/container/releases/latest/download/container-installer-signed.pkg",
        "sudo installer -pkg /tmp/container-installer-signed.pkg -target /",
        "container system start"
      ]
    });
    return { checks, ok: checks.every((check) => check.ok) };
  }

  checks.push({
    key: "container-bin",
    ok: true,
    message: `container CLI found at ${containerBin}`
  });

  try {
    const version = await getContainerVersion(containerBin);
    checks.push({
      key: "container-version",
      ok: true,
      message: version
    });
  } catch (error) {
    checks.push({
      key: "container-version",
      ok: false,
      message: error instanceof Error ? error.message : String(error),
      fix: "Verify container CLI is correctly installed."
    });
  }

  try {
    const runtime = await getRuntimeStatus(containerBin);
    checks.push({
      key: "container-runtime",
      ok: runtime.running,
      message: runtime.running ? "container runtime is running" : "container runtime is not running",
      fix: runtime.running ? undefined : "Run `container system start`.",
      suggestedCommands: runtime.running ? undefined : ["container system start"]
    });
  } catch (error) {
    checks.push({
      key: "container-runtime",
      ok: false,
      message: error instanceof Error ? error.message : String(error),
      fix: "Run `container system start` and retry.",
      suggestedCommands: ["container system start"]
    });
  }

  return { checks, ok: checks.every((check) => check.ok) };
}
