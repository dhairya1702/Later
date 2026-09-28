import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import test from "node:test";
import { apnsConfigured, makeProviderToken } from "../apns.mjs";

test("APNs provider token is a correctly shaped ES256 JWT", () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const configuration = {
    APNS_KEY_ID: "JUGJUPBAHM",
    APNS_TEAM_ID: "X34H6AHCUU",
    APNS_TOPIC: "com.dhairyalalwani.Later",
    APNS_PRIVATE_KEY: privateKey.export({ type: "pkcs8", format: "pem" }),
  };

  assert.equal(apnsConfigured(configuration), true);
  const parts = makeProviderToken(configuration, 1_700_000_000_000).split(".");
  assert.equal(parts.length, 3);
  assert.deepEqual(JSON.parse(Buffer.from(parts[0], "base64url")), {
    alg: "ES256",
    kid: "JUGJUPBAHM",
  });
  assert.deepEqual(JSON.parse(Buffer.from(parts[1], "base64url")), {
    iss: "X34H6AHCUU",
    iat: 1_700_000_000,
  });
  assert.equal(Buffer.from(parts[2], "base64url").length, 64);
});

test("APNs reports missing configuration", () => {
  assert.equal(apnsConfigured({}), false);
});
