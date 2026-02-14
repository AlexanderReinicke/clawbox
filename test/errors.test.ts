import test from "node:test";
import assert from "node:assert/strict";
import { CommandError } from "../src/lib/exec";
import { CliError, renderCliError, toCliError } from "../src/lib/errors";

test("toCliError preserves existing CliError", () => {
  const input = new CliError({
    kind: "validation",
    message: "bad input",
    hint: "try again"
  });
  const output = toCliError(input);
  assert.equal(output, input);
});

test("toCliError maps CommandError to runtime CliError with detail", () => {
  const commandError = new CommandError("foo bar", 7, "std out", "std err");
  const mapped = toCliError(commandError);
  assert.equal(mapped.kind, "runtime");
  assert.equal(mapped.message, "Command failed (7): foo bar");
  assert.equal(mapped.detail, "std out\nstd err");
});

test("renderCliError includes hint and detail on separate lines", () => {
  const err = new CliError({
    kind: "dependency",
    message: "runtime missing",
    hint: "run container system start",
    detail: "apiserver is not running"
  });
  const rendered = renderCliError(err);
  assert.equal(rendered, "runtime missing\nHint: run container system start\napiserver is not running");
});
