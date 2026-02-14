import test from "node:test";
import assert from "node:assert/strict";
import { CliError } from "../src/lib/errors";
import { formatInstanceNotFoundMessage, requireInstanceByName } from "../src/lib/instances";
import type { InstanceInfo } from "../src/lib/types";

test("formatInstanceNotFoundMessage includes available names when present", () => {
  const message = formatInstanceNotFoundMessage("alpha", ["one", "two"]);
  assert.equal(message, "Instance 'alpha' not found. Available instances: one, two");
});

test("formatInstanceNotFoundMessage explains empty state", () => {
  const message = formatInstanceNotFoundMessage("alpha", []);
  assert.equal(message, "Instance 'alpha' not found. No clawbox instances exist yet.");
});

test("requireInstanceByName throws CliError with kind=not_found", () => {
  const instances: InstanceInfo[] = [];
  assert.throws(
    () => requireInstanceByName(instances, "alpha"),
    (error: unknown) => error instanceof CliError
      && error.kind === "not_found"
      && error.message.includes("No clawbox instances exist yet")
  );
});
