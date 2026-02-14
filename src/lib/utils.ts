import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const APPLE_REFERENCE_EPOCH_MS = Date.UTC(2001, 0, 1);

export function roundTo(value: number, digits = 2): number {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

export function formatGb(value?: number): string {
  if (typeof value !== "number" || Number.isNaN(value)) {
    return "-";
  }
  return `${roundTo(value, 2)} GB`;
}

export function normalizeIPv4(raw?: string): string | undefined {
  if (!raw) {
    return undefined;
  }
  return raw.split("/")[0];
}

export function parseMaybeNumber(value: unknown): number | undefined {
  if (typeof value === "number") {
    return Number.isFinite(value) ? value : undefined;
  }
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

export function parseContainerTimestamp(value: unknown): Date | undefined {
  const numeric = parseMaybeNumber(value);
  if (typeof numeric !== "number") {
    return undefined;
  }

  if (numeric <= 0) {
    return undefined;
  }

  if (numeric < 1_000_000_000) {
    return new Date(APPLE_REFERENCE_EPOCH_MS + numeric * 1000);
  }
  return new Date(numeric * 1000);
}

export function resolveExistingDirectory(inputPath: string): string {
  const resolvedInput = normalizeInputPath(inputPath);
  const resolved = path.resolve(resolvedInput);
  const stat = fs.statSync(resolved, { throwIfNoEntry: false });
  if (!stat || !stat.isDirectory()) {
    throw new Error(`Mount path does not exist or is not a directory: ${resolved}`);
  }
  return resolved;
}

export function normalizeInputPath(inputPath: string): string {
  const trimmed = inputPath.trim();
  if (trimmed === "~") {
    return os.homedir();
  }
  if (trimmed.startsWith("~/")) {
    return path.join(os.homedir(), trimmed.slice(2));
  }
  return trimmed;
}

export function getTtyName(): string {
  return process.stdout.isTTY ? "interactive" : "non-interactive";
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
