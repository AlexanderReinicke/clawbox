import path from "node:path";
import ora from "ora";
import { DEFAULT_IMAGE_TAG } from "./constants";
import { runCommand } from "./exec";
import { getTemplateDockerfilePath } from "./runtime";

export async function imageExists(containerBin: string, imageTag = DEFAULT_IMAGE_TAG): Promise<boolean> {
  const result = await runCommand(containerBin, ["image", "ls"], { timeoutMs: 20_000 });
  const lines = result.stdout.split("\n").map((line) => line.trim()).filter(Boolean);

  for (const line of lines) {
    if (line.startsWith("NAME") || line.startsWith("ID")) {
      continue;
    }
    const columns = line.split(/\s+/);
    if (columns.length < 2) {
      continue;
    }
    const candidate = `${columns[0]}:${columns[1]}`;
    if (candidate === imageTag) {
      return true;
    }
  }

  return false;
}

export async function ensureDefaultImage(containerBin: string, imageTag = DEFAULT_IMAGE_TAG): Promise<void> {
  if (await imageExists(containerBin, imageTag)) {
    return;
  }

  const dockerfilePath = getTemplateDockerfilePath();
  const contextDir = path.dirname(dockerfilePath);

  const spinner = ora("Building default clawbox image (first build can take 30-60s)...").start();
  try {
    await runCommand(containerBin, ["build", "-t", imageTag, contextDir], { timeoutMs: 300_000 });
    spinner.succeed("Default image built.");
  } catch (error) {
    spinner.fail("Image build failed.");
    throw error;
  }
}
