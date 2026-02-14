import fs from "node:fs";
import path from "node:path";

interface PackageMeta {
  name?: string;
  version?: string;
}

export function readPackageMeta(): PackageMeta {
  const candidates = [
    path.resolve(__dirname, "../../package.json"),
    path.resolve(__dirname, "../package.json"),
    path.resolve(process.cwd(), "package.json")
  ];

  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) {
      continue;
    }

    try {
      const raw = fs.readFileSync(candidate, "utf8");
      return JSON.parse(raw) as PackageMeta;
    } catch {
      continue;
    }
  }

  return {};
}
