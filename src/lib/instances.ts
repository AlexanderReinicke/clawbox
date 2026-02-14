import fs from "node:fs";
import {
  DEFAULT_IMAGE_TAG,
  DEFAULT_RAM_GB,
  DEFAULT_TEMPLATE_MOUNT_PATH,
  INSTANCE_CREATED_AT_LABEL,
  INSTANCE_KEEP_AWAKE_LABEL,
  INSTANCE_MOUNT_LABEL,
  INSTANCE_NAME_LABEL,
  INSTANCE_PREFIX,
  INSTANCE_RAM_LABEL,
  MANAGED_LABEL
} from "./constants";
import { runCommand } from "./exec";
import type { InstanceInfo, InstanceStatus } from "./types";
import {
  isRecord,
  normalizeIPv4,
  parseContainerTimestamp,
  parseMaybeNumber,
  resolveExistingDirectory,
  roundTo,
  normalizeInputPath
} from "./utils";
import {
  readKeepAwakePreferences,
  removeKeepAwakePreference,
  setKeepAwakePreference
} from "./instance-preferences";

let supportsLabelCache: boolean | null = null;

interface ContainerListEntry {
  status?: unknown;
  configuration?: unknown;
  networks?: unknown;
  startedDate?: unknown;
}

export function toInternalName(instanceName: string): string {
  return `${INSTANCE_PREFIX}${instanceName}`;
}

export function toUserName(internalName: string): string {
  if (internalName.startsWith(INSTANCE_PREFIX)) {
    return internalName.slice(INSTANCE_PREFIX.length);
  }
  return internalName;
}

export function validateInstanceName(name: string): string | null {
  if (!name.trim()) {
    return "Instance name is required.";
  }
  if (!/^[a-zA-Z0-9-]+$/.test(name)) {
    return "Name must contain only letters, numbers, and hyphens.";
  }
  return null;
}

export async function listManagedInstances(containerBin: string): Promise<InstanceInfo[]> {
  const keepAwakePreferences = await readKeepAwakePreferences();
  const entries = await listAllContainers(containerBin);
  const managedCandidates = entries
    .map(normalizeListEntry)
    .filter((entry): entry is NormalizedListEntry => Boolean(entry))
    .filter((entry) => isManagedFromListEntry(entry));

  const instances: InstanceInfo[] = [];
  for (const entry of managedCandidates) {
    const inspected = await inspectContainer(containerBin, entry.internalName);
    instances.push(mergeInstanceData(entry, inspected, keepAwakePreferences));
  }

  return instances.sort((a, b) => a.name.localeCompare(b.name));
}

export async function listAllContainerNames(containerBin: string): Promise<Set<string>> {
  const result = await runCommand(containerBin, ["ls", "-a"], { timeoutMs: 20_000 });
  const names = new Set<string>();
  for (const line of result.stdout.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || /^id\s+/i.test(trimmed)) {
      continue;
    }
    const token = trimmed.split(/\s+/)[0];
    if (token) {
      names.add(token);
    }
  }
  return names;
}

export async function createManagedInstance(
  containerBin: string,
  options: {
    name: string;
    ramGb: number;
    mountPath?: string;
    keepAwake?: boolean;
    imageTag?: string;
  }
): Promise<void> {
  const internalName = toInternalName(options.name);
  const imageTag = options.imageTag ?? DEFAULT_IMAGE_TAG;

  const args = ["create", "--name", internalName, "-m", `${options.ramGb}G`];
  if (options.mountPath) {
    const resolvedMount = resolveExistingDirectory(options.mountPath);
    args.push("-v", `${resolvedMount}:${DEFAULT_TEMPLATE_MOUNT_PATH}`);
  }

  if (await supportsLabels(containerBin)) {
    const labels: Array<[string, string]> = [
      [MANAGED_LABEL, "true"],
      [INSTANCE_NAME_LABEL, options.name],
      [INSTANCE_RAM_LABEL, String(options.ramGb)],
      [INSTANCE_KEEP_AWAKE_LABEL, options.keepAwake === false ? "false" : "true"],
      [INSTANCE_CREATED_AT_LABEL, new Date().toISOString()]
    ];
    if (options.mountPath) {
      labels.push([INSTANCE_MOUNT_LABEL, resolveExistingDirectory(options.mountPath)]);
    }

    for (const [key, value] of labels) {
      args.push("--label", `${key}=${value}`);
    }
  }

  args.push(imageTag, "sleep", "infinity");
  await runCommand(containerBin, args, { timeoutMs: 120_000 });
  await setKeepAwakePreference(internalName, options.keepAwake !== false);
}

export async function startManagedInstance(containerBin: string, internalName: string): Promise<void> {
  await runCommand(containerBin, ["start", internalName], { timeoutMs: 60_000 });
}

export async function pauseManagedInstance(containerBin: string, internalName: string): Promise<void> {
  await runCommand(containerBin, ["stop", internalName], { timeoutMs: 60_000 });
}

export async function deleteManagedInstance(containerBin: string, internalName: string): Promise<void> {
  await runCommand(containerBin, ["rm", internalName], { timeoutMs: 60_000 });
  await removeKeepAwakePreference(internalName);
}

export async function waitForInstanceIp(
  containerBin: string,
  internalName: string,
  timeoutMs = 30_000
): Promise<string | undefined> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    const inspected = await inspectContainer(containerBin, internalName);
    const ip = inspected.ip;
    if (ip) {
      return ip;
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }

  const finalInspect = await inspectContainer(containerBin, internalName);
  return finalInspect.ip;
}

export async function inspectManagedInstance(containerBin: string, name: string): Promise<InstanceInfo | null> {
  const targetInternal = toInternalName(name);
  const instances = await listManagedInstances(containerBin);
  return instances.find((instance) => instance.internalName === targetInternal) ?? null;
}

async function supportsLabels(containerBin: string): Promise<boolean> {
  if (supportsLabelCache !== null) {
    return supportsLabelCache;
  }

  const help = await runCommand(containerBin, ["create", "--help"], {
    timeoutMs: 10_000,
    allowNonZeroExit: true
  });
  const text = `${help.stdout}\n${help.stderr}`.toLowerCase();
  supportsLabelCache = text.includes("--label");
  return supportsLabelCache;
}

async function listAllContainers(containerBin: string): Promise<ContainerListEntry[]> {
  const result = await runCommand(containerBin, ["ls", "--all", "--format", "json"], {
    allowNonZeroExit: true,
    timeoutMs: 30_000
  });

  if (result.exitCode === 0 && result.stdout.trim().startsWith("[")) {
    const parsed = JSON.parse(result.stdout) as unknown;
    if (Array.isArray(parsed)) {
      return parsed as ContainerListEntry[];
    }
  }

  const fallback = await runCommand(containerBin, ["ls", "-a"], { timeoutMs: 20_000 });
  const entries: ContainerListEntry[] = [];
  for (const line of fallback.stdout.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || /^id\s+/i.test(trimmed)) {
      continue;
    }
    const token = trimmed.split(/\s+/)[0];
    if (!token) {
      continue;
    }
    entries.push({
      status: trimmed.toLowerCase().includes("running") ? "running" : "stopped",
      configuration: { id: token }
    });
  }
  return entries;
}

interface NormalizedListEntry {
  internalName: string;
  status: InstanceStatus;
  ip?: string;
  ramGb?: number;
  startedAt?: Date;
  labels: Record<string, string>;
}

function normalizeListEntry(input: ContainerListEntry): NormalizedListEntry | null {
  const config = isRecord(input.configuration) ? input.configuration : {};
  const internalName = stringField(config.id) ?? "";
  if (!internalName) {
    return null;
  }

  const resources = isRecord(config.resources) ? config.resources : {};
  const labels = asStringRecord(config.labels);

  const networkAttachments = Array.isArray(input.networks) ? input.networks : [];
  let ip: string | undefined;
  for (const network of networkAttachments) {
    if (!isRecord(network)) {
      continue;
    }
    const maybe = normalizeIPv4(stringField(network.ipv4Address));
    if (maybe) {
      ip = maybe;
      break;
    }
  }

  const memoryBytes = parseMaybeNumber(resources.memoryInBytes);
  const ramGb = typeof memoryBytes === "number" ? roundTo(memoryBytes / (1024 ** 3), 2) : undefined;

  return {
    internalName,
    status: normalizeStatus(stringField(input.status)),
    ip,
    ramGb,
    startedAt: parseContainerTimestamp(input.startedDate),
    labels
  };
}

function isManagedFromListEntry(entry: NormalizedListEntry): boolean {
  return entry.labels[MANAGED_LABEL] === "true" || entry.internalName.startsWith(INSTANCE_PREFIX);
}

interface InspectedDetails {
  labels: Record<string, string>;
  mountPath?: string;
  ramGb?: number;
  ip?: string;
  createdAt?: Date;
  startedAt?: Date;
  status?: InstanceStatus;
}

async function inspectContainer(containerBin: string, internalName: string): Promise<InspectedDetails> {
  const result = await runCommand(containerBin, ["inspect", internalName], {
    allowNonZeroExit: true,
    timeoutMs: 20_000
  });
  if (result.exitCode !== 0 || !result.stdout.trim()) {
    return { labels: {} };
  }

  const parsed = JSON.parse(result.stdout) as unknown;
  const root = Array.isArray(parsed) ? parsed[0] : parsed;
  if (!isRecord(root)) {
    return { labels: {} };
  }

  const config = isRecord(root.configuration) ? root.configuration : {};
  const resources = isRecord(config.resources) ? config.resources : {};

  const labels = {
    ...asStringRecord(root.labels),
    ...asStringRecord(config.labels)
  };

  const memoryBytes = parseMaybeNumber(resources.memoryInBytes);
  const ramGb = typeof memoryBytes === "number" ? roundTo(memoryBytes / (1024 ** 3), 2) : undefined;

  const networks = Array.isArray(root.networks) ? root.networks : [];
  let ip: string | undefined;
  for (const network of networks) {
    if (!isRecord(network)) {
      continue;
    }
    const maybe = normalizeIPv4(stringField(network.ipv4Address));
    if (maybe) {
      ip = maybe;
      break;
    }
  }

  const mountPath = extractMountPath(root);
  const createdAt = parseISODate(labels[INSTANCE_CREATED_AT_LABEL]) ?? parseContainerTimestamp(root.createdDate);
  const startedAt = parseContainerTimestamp(root.startedDate);

  return {
    labels,
    mountPath,
    ramGb,
    ip,
    createdAt,
    startedAt,
    status: normalizeStatus(stringField(root.status))
  };
}

function mergeInstanceData(
  listEntry: NormalizedListEntry,
  inspected: InspectedDetails,
  keepAwakePreferences: Record<string, boolean>
): InstanceInfo {
  const mergedLabels = {
    ...listEntry.labels,
    ...inspected.labels
  };

  const internalName = listEntry.internalName;
  const labeledName = mergedLabels[INSTANCE_NAME_LABEL];
  const name = labeledName || toUserName(internalName);

  const ramFromLabel = parseMaybeNumber(mergedLabels[INSTANCE_RAM_LABEL]);
  const mountFromLabel = mergedLabels[INSTANCE_MOUNT_LABEL];
  const keepAwake = parseLabelBoolean(mergedLabels[INSTANCE_KEEP_AWAKE_LABEL]);
  const keepAwakeFromPreference = keepAwakePreferences[internalName];

  return {
    name,
    internalName,
    status: inspected.status ?? listEntry.status,
    keepAwake: keepAwakeFromPreference ?? keepAwake ?? true,
    ip: inspected.ip ?? listEntry.ip,
    ramGb: inspected.ramGb ?? listEntry.ramGb ?? ramFromLabel ?? DEFAULT_RAM_GB,
    mountPath: inspected.mountPath ?? mountFromLabel,
    createdAt: inspected.createdAt,
    startedAt: inspected.startedAt ?? listEntry.startedAt
  };
}

function parseLabelBoolean(value?: string): boolean | undefined {
  if (!value) {
    return undefined;
  }

  const normalized = value.trim().toLowerCase();
  if (["1", "true", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["0", "false", "no", "off"].includes(normalized)) {
    return false;
  }
  return undefined;
}

function extractMountPath(root: Record<string, unknown>): string | undefined {
  const config = isRecord(root.configuration) ? root.configuration : {};
  const mountLists = [config.mounts, root.mounts].filter(Array.isArray) as unknown[][];

  for (const mountList of mountLists) {
    for (const mount of mountList) {
      if (!isRecord(mount)) {
        continue;
      }
      const target = stringField(mount.target) ?? stringField(mount.containerPath) ?? stringField(mount.destination);
      const source = stringField(mount.source) ?? stringField(mount.hostPath) ?? stringField(mount.path);

      if (!source) {
        continue;
      }

      if (target === DEFAULT_TEMPLATE_MOUNT_PATH) {
        return source;
      }
    }
  }

  return undefined;
}

function asStringRecord(value: unknown): Record<string, string> {
  if (!isRecord(value)) {
    return {};
  }

  return Object.entries(value).reduce<Record<string, string>>((acc, [key, raw]) => {
    if (typeof raw === "string") {
      acc[key] = raw;
    }
    return acc;
  }, {});
}

function normalizeStatus(raw?: string): InstanceStatus {
  const value = (raw || "").toLowerCase();
  if (value === "running") {
    return "running";
  }
  if (["stopped", "paused", "created", "exited"].includes(value)) {
    return "stopped";
  }
  return "unknown";
}

function stringField(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function parseISODate(value?: string): Date | undefined {
  if (!value) {
    return undefined;
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return undefined;
  }
  return parsed;
}

export function ensureUniqueInstanceName(name: string, existing: Set<string>): void {
  const internalName = toInternalName(name);
  if (existing.has(internalName)) {
    throw new Error(`An instance named '${name}' already exists. Choose a different name or delete the existing instance.`);
  }
}

export function ensureMountPathSafe(mountPath?: string): string | undefined {
  if (!mountPath) {
    return undefined;
  }
  const normalized = normalizeInputPath(mountPath);
  if (!fs.existsSync(normalized)) {
    throw new Error(`Mount path does not exist: ${normalized}`);
  }
  return resolveExistingDirectory(normalized);
}
