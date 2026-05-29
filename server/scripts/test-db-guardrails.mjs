import assert from "node:assert/strict";

process.env.OUNJE_GUARDRAILS_ENABLED = "1";
process.env.OUNJE_DB_SLOW_MS = "10";
process.env.OUNJE_GUARDRAIL_DEGRADED_SLOW_EVENTS = "2";
process.env.OUNJE_GUARDRAIL_DEGRADED_ERROR_EVENTS = "2";
process.env.OUNJE_NONESSENTIAL_RETRY_AFTER_SECONDS = "17";
process.env.OUNJE_REDIS_MAX_JSON_BYTES = "16384";

const {
  getGuardrailState,
  maybeBlockNonEssentialDuringDegraded,
  recordDbOperation,
} = await import("../lib/db-guardrails.js");

function mockResponse() {
  const headers = new Map();
  return {
    statusCode: null,
    payload: null,
    set(name, value) {
      headers.set(name, value);
      return this;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(payload) {
      this.payload = payload;
      return this;
    },
    header(name) {
      return headers.get(name);
    },
  };
}

let nextCalled = 0;
maybeBlockNonEssentialDuringDegraded(
  { method: "POST", path: "/v1/recipe/discover" },
  mockResponse(),
  () => { nextCalled += 1; }
);
assert.equal(nextCalled, 1, "log mode should not block before degraded state");

recordDbOperation({
  operation: "test-slow-one",
  method: "GET",
  path: "/rest/v1/recipes?select=id",
  durationMs: 125,
  ok: true,
  status: 200,
});
recordDbOperation({
  operation: "test-slow-two",
  method: "GET",
  path: "/rest/v1/user_import_recipes?select=id",
  durationMs: 122,
  ok: true,
  status: 200,
});

assert.equal(getGuardrailState().degraded, true, "slow events should mark guardrail degraded");

process.env.OUNJE_CIRCUIT_BREAKER_MODE = "enforce";
const nonEssentialResponse = mockResponse();
maybeBlockNonEssentialDuringDegraded(
  { method: "POST", path: "/v1/recipe/discover" },
  nonEssentialResponse,
  () => { throw new Error("nonessential route should be blocked in enforce mode"); }
);
assert.equal(nonEssentialResponse.statusCode, 503);
assert.equal(nonEssentialResponse.payload.code, "temporarily_degraded");
assert.equal(nonEssentialResponse.payload.retry_after_seconds, 17);
assert.equal(nonEssentialResponse.header("Retry-After"), "17");

const essentialResponse = mockResponse();
let essentialNextCalled = 0;
maybeBlockNonEssentialDuringDegraded(
  { method: "GET", path: "/v1/recipe/imports/ri_test" },
  essentialResponse,
  () => { essentialNextCalled += 1; }
);
assert.equal(essentialNextCalled, 1, "essential import status route must remain available");

const { writeRedisJSON } = await import("../lib/redis-cache.js");
const oversizedStored = await writeRedisJSON(
  "guardrail-test:oversized",
  { payload: "x".repeat(20_000) },
  60
);
assert.equal(oversizedStored, false, "oversized Redis payloads should be skipped safely");

console.log("[test-db-guardrails] ok");
