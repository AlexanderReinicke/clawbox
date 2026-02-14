import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/cli.ts"],
  format: ["cjs"],
  target: "node18",
  platform: "node",
  clean: true,
  sourcemap: true,
  splitting: false,
  shims: false,
  outDir: "dist"
});
