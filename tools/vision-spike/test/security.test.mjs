import assert from "node:assert/strict";
import {
  createHash,
  generateKeyPairSync,
  sign,
} from "node:crypto";
import test from "node:test";
import { encode } from "cbor-x";
import {
  BackendSecurity,
  SecurityError,
  nextQuotaState,
  signToken,
  verifyAssertion,
  verifyToken,
} from "../security.mjs";

const secret = "a-test-session-secret-that-is-at-least-32-bytes-long";
const now = Date.UTC(2026, 8, 28, 12);

test("signed security tokens reject tampering and expiration", () => {
  const token = signToken({
    type: "session",
    sub: "installation",
    exp: Math.floor((now + 60_000) / 1000),
  }, secret);
  assert.equal(verifyToken(token, secret, "session", now).sub, "installation");

  assert.throws(
    () => verifyToken(`${token}x`, secret, "session", now),
    SecurityError,
  );
  assert.throws(
    () => verifyToken(token, secret, "session", now + 60_000),
    /expired/,
  );
});

test("App Attest assertions are bound to the app, challenge, and counter", () => {
  const appID = "X34H6AHCUU.com.dhairyalalwani.Later";
  const clientDataHash = createHash("sha256").update("challenge").digest();
  const authenticatorData = Buffer.alloc(37);
  createHash("sha256").update(appID).digest().copy(authenticatorData, 0);
  authenticatorData.writeUInt32BE(7, 33);

  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const signature = sign(
    "sha256",
    Buffer.concat([authenticatorData, clientDataHash]),
    privateKey,
  );
  const assertion = encode({ authenticatorData, signature });
  const result = verifyAssertion({
    assertion,
    clientDataHash,
    publicKey: publicKey.export({ type: "spki", format: "pem" }),
    appID,
  });
  assert.equal(result.counter, 7);

  assert.throws(() => verifyAssertion({
    assertion,
    clientDataHash: createHash("sha256").update("other challenge").digest(),
    publicKey: publicKey.export({ type: "spki", format: "pem" }),
    appID,
  }), /signature/);
  assert.throws(() => verifyAssertion({
    assertion,
    clientDataHash,
    publicKey: publicKey.export({ type: "spki", format: "pem" }),
    appID: "X34H6AHCUU.com.example.Impostor",
  }), /identity/);
});

test("analysis accepts scoped sessions and applies installation and global quotas", async () => {
  const calls = [];
  const store = {
    async consumeInstallationQuota(id, policy) { calls.push(["installation", id, policy]); },
    async consumeGlobalQuota(policy) { calls.push(["global", policy]); },
  };
  const security = new BackendSecurity({
    environment: { LATER_SESSION_SECRET: secret },
    store,
    now: () => now,
  });
  const token = signToken({
    type: "session",
    sub: "real-installation",
    exp: Math.floor((now + 60_000) / 1000),
  }, secret);
  const result = await security.authorizeAnalysis({
    headers: { authorization: `AppAttest ${token}` },
    socket: {},
  });

  assert.deepEqual(result, { mode: "app-attest", installationID: "real-installation" });
  assert.equal(calls[0][0], "installation");
  assert.equal(calls[0][1], "real-installation");
  assert.equal(calls[0][2].dailyLimit, 300);
  assert.equal(calls[0][2].burstLimit, 120);
  assert.equal(calls[1][0], "global");
});

test("legacy builds remain rate limited during migration and can be disabled", async () => {
  const calls = [];
  const store = {
    async consumeLegacyQuota(id) { calls.push(["legacy", id]); },
    async consumeGlobalQuota() { calls.push(["global"]); },
  };
  const request = {
    headers: {
      authorization: "Bearer existing-token",
      "x-later-install-id": "74bba86d-e935-4b30-a643-dc00e0ebbc62",
    },
    socket: {},
  };
  const security = new BackendSecurity({
    environment: {
      LATER_API_TOKEN: "existing-token",
      LATER_SESSION_SECRET: secret,
      APP_ATTEST_TEAM_ID: "X34H6AHCUU",
      APP_ATTEST_BUNDLE_ID: "com.dhairyalalwani.Later",
    },
    store,
    now: () => now,
  });
  assert.deepEqual(await security.authorizeAnalysis(request), { mode: "legacy" });
  assert.equal(calls.length, 2);
  assert.match(calls[0][1], /^[a-f\d]{64}$/);

  const disabled = new BackendSecurity({
    environment: {
      LATER_API_TOKEN: "existing-token",
      LATER_SESSION_SECRET: secret,
      APP_ATTEST_TEAM_ID: "X34H6AHCUU",
      APP_ATTEST_BUNDLE_ID: "com.dhairyalalwani.Later",
      ALLOW_LEGACY_TOKEN: "false",
    },
    store,
    now: () => now,
  });
  await assert.rejects(() => disabled.authorizeAnalysis(request), (error) => {
    assert.equal(error.status, 426);
    assert.equal(error.code, "update_required");
    return true;
  });
});

test("quota state enforces burst and daily limits and resets its windows", () => {
  const policy = { dailyLimit: 3, burstLimit: 2, burstWindowMs: 300_000 };
  const first = nextQuotaState({}, policy, now);
  const second = nextQuotaState(first, policy, now + 1_000);
  assert.equal(second.dailyCount, 2);
  assert.equal(second.burstCount, 2);
  assert.throws(
    () => nextQuotaState(second, policy, now + 2_000),
    (error) => error.code === "burst_limit" && error.retryAfter === 298,
  );

  const afterBurst = nextQuotaState(second, policy, now + 300_001);
  assert.equal(afterBurst.dailyCount, 3);
  assert.equal(afterBurst.burstCount, 1);
  assert.throws(
    () => nextQuotaState(afterBurst, policy, now + 301_000),
    (error) => error.code === "daily_limit" && error.status === 429,
  );

  const tomorrow = now + 24 * 60 * 60 * 1000;
  const reset = nextQuotaState(afterBurst, policy, tomorrow);
  assert.equal(reset.dailyCount, 1);
});
