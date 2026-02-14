import fs from "node:fs";
import os from "node:os";
import path from "node:path";

interface PreferenceFile {
  keepAwakeByInternalName?: Record<string, boolean>;
}

const PREFERENCES_DIR = path.join(os.homedir(), ".clawbox");
const PREFERENCES_PATH = path.join(PREFERENCES_DIR, "instance-preferences.json");

export async function readKeepAwakePreferences(): Promise<Record<string, boolean>> {
  const file = await readPreferenceFile();
  return file.keepAwakeByInternalName ?? {};
}

export async function setKeepAwakePreference(internalName: string, keepAwake: boolean): Promise<void> {
  const file = await readPreferenceFile();
  const keepAwakeByInternalName = {
    ...(file.keepAwakeByInternalName ?? {}),
    [internalName]: keepAwake
  };
  await writePreferenceFile({ keepAwakeByInternalName });
}

export async function removeKeepAwakePreference(internalName: string): Promise<void> {
  const file = await readPreferenceFile();
  const keepAwakeByInternalName = { ...(file.keepAwakeByInternalName ?? {}) };
  delete keepAwakeByInternalName[internalName];
  await writePreferenceFile({ keepAwakeByInternalName });
}

async function readPreferenceFile(): Promise<PreferenceFile> {
  try {
    const raw = await fs.promises.readFile(PREFERENCES_PATH, "utf8");
    const parsed = JSON.parse(raw) as unknown;
    if (!isRecord(parsed)) {
      return {};
    }

    const rawMap = parsed.keepAwakeByInternalName;
    if (!isRecord(rawMap)) {
      return {};
    }

    const keepAwakeByInternalName: Record<string, boolean> = {};
    for (const [key, value] of Object.entries(rawMap)) {
      if (typeof value === "boolean") {
        keepAwakeByInternalName[key] = value;
      }
    }

    return { keepAwakeByInternalName };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return {};
    }
    return {};
  }
}

async function writePreferenceFile(file: PreferenceFile): Promise<void> {
  await fs.promises.mkdir(PREFERENCES_DIR, { recursive: true });
  await fs.promises.writeFile(PREFERENCES_PATH, `${JSON.stringify(file, null, 2)}\n`, "utf8");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
