import test from "node:test";
import assert from "node:assert/strict";
import { isGatewayTokenMissingLog } from "../src/lib/gateway";

test("isGatewayTokenMissingLog detects token configuration failure", () => {
  const log = "2026-02-14T02:50:41.843+00:00 Gateway auth is set to token, but no token is configured.";
  assert.equal(isGatewayTokenMissingLog(log), true);
});

test("isGatewayTokenMissingLog ignores unrelated logs", () => {
  const log = "gateway started";
  assert.equal(isGatewayTokenMissingLog(log), false);
});
