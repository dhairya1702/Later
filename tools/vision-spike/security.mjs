import {
  X509Certificate,
  createHash,
  createHmac,
  createPublicKey,
  randomBytes,
  timingSafeEqual,
  verify as verifySignature,
} from "node:crypto";
import { readFileSync } from "node:fs";
import { Firestore } from "@google-cloud/firestore";
import { decode } from "cbor-x";

const appleRootPEM = readFileSync(new URL(
  "./Apple_App_Attestation_Root_CA.pem",
  import.meta.url,
), "utf8");
const appleRoot = new X509Certificate(appleRootPEM);
const nonceExtensionOID = Buffer.from("06092a864886f763640802", "hex");

export class SecurityError extends Error {
  constructor(message, { status = 401, code = "unauthorized", retryAfter } = {}) {
    super(message);
    this.name = "SecurityError";
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

export class FirestoreSecurityStore {
  constructor({ firestore = new Firestore() } = {}) {
    this.firestore = firestore;
  }

  async createInstallation(id, installation) {
    const reference = this.firestore.collection("laterAppAttestInstallations").doc(id);
    await this.firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reference);
      if (snapshot.exists) {
        throw new SecurityError("This App Attest key is already registered", {
          status: 409,
          code: "already_registered",
        });
      }
      transaction.create(reference, {
        ...installation,
        assertionCounter: 0,
        disabled: false,
        createdAt: Date.now(),
        lastSeenAt: Date.now(),
      });
    });
  }

  async installation(id) {
    const snapshot = await this.firestore
      .collection("laterAppAttestInstallations")
      .doc(id)
      .get();
    return snapshot.exists ? snapshot.data() : null;
  }

  async advanceAssertionCounter(id, counter) {
    const reference = this.firestore.collection("laterAppAttestInstallations").doc(id);
    await this.firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) {
        throw new SecurityError("Unknown App Attest key", {
          status: 404,
          code: "unknown_key",
        });
      }
      const installation = snapshot.data();
      if (installation.disabled) throw new SecurityError("This installation is disabled");
      if (counter <= Number(installation.assertionCounter || 0)) {
        throw new SecurityError("Replayed App Attest assertion", {
          status: 409,
          code: "replayed_assertion",
        });
      }
      transaction.update(reference, { assertionCounter: counter, lastSeenAt: Date.now() });
    });
  }

  async consumeInstallationQuota(id, policy, now = Date.now()) {
    const reference = this.firestore.collection("laterAppAttestInstallations").doc(id);
    return this.#consumeQuota(reference, policy, now, { requireExisting: true });
  }

  async consumeLegacyQuota(id, policy, now = Date.now()) {
    const reference = this.firestore.collection("laterLegacyRateLimits").doc(id);
    return this.#consumeQuota(reference, policy, now, { requireExisting: false });
  }

  async consumeGlobalQuota(policy, now = Date.now()) {
    const day = utcDay(now);
    const reference = this.firestore.collection("laterGlobalRateLimits").doc(day);
    return this.#consumeQuota(reference, {
      dailyLimit: policy.dailyLimit,
      burstLimit: policy.dailyLimit,
      burstWindowMs: 24 * 60 * 60 * 1000,
    }, now, { requireExisting: false });
  }

  async #consumeQuota(reference, policy, now, { requireExisting }) {
    return this.firestore.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reference);
      if (requireExisting && !snapshot.exists) {
        throw new SecurityError("Unknown App Attest installation", {
          status: 401,
          code: "unknown_installation",
        });
      }

      const value = snapshot.exists ? snapshot.data() : {};
      if (value.disabled) throw new SecurityError("This installation is disabled");
      const update = nextQuotaState(value, policy, now);
      if (snapshot.exists) transaction.update(reference, update);
      else transaction.create(reference, update);
      return update;
    });
  }
}

export function nextQuotaState(value, policy, now) {
  const day = utcDay(now);
  const dailyCount = value.quotaDay === day ? Number(value.dailyCount || 0) : 0;
  const windowStartedAt = Number(value.windowStartedAt || 0);
  const sameWindow = now - windowStartedAt < policy.burstWindowMs;
  const burstCount = sameWindow ? Number(value.burstCount || 0) : 0;

  if (dailyCount >= policy.dailyLimit) {
    throw new SecurityError("Daily analysis limit reached", {
      status: 429,
      code: "daily_limit",
      retryAfter: secondsUntilTomorrow(now),
    });
  }
  if (burstCount >= policy.burstLimit) {
    throw new SecurityError("Too many analyses in a short period", {
      status: 429,
      code: "burst_limit",
      retryAfter: Math.max(1, Math.ceil(
        (policy.burstWindowMs - (now - windowStartedAt)) / 1000,
      )),
    });
  }

  return {
    quotaDay: day,
    dailyCount: dailyCount + 1,
    windowStartedAt: sameWindow ? windowStartedAt : now,
    burstCount: burstCount + 1,
    lastSeenAt: now,
  };
}

export class BackendSecurity {
  constructor({ environment = process.env, store, now = () => Date.now() } = {}) {
    this.environment = environment;
    this.store = store || new FirestoreSecurityStore();
    this.now = now;
  }

  get configured() {
    return Boolean(
      this.#sessionSecret(false)
      && this.environment.APP_ATTEST_TEAM_ID?.trim()
      && this.environment.APP_ATTEST_BUNDLE_ID?.trim(),
    );
  }

  makeChallenge() {
    const now = this.now();
    return signToken({
      type: "challenge",
      nonce: randomBytes(32).toString("base64url"),
      iat: Math.floor(now / 1000),
      exp: Math.floor((now + 5 * 60 * 1000) / 1000),
    }, this.#sessionSecret());
  }

  async attest({ keyID, challenge, attestationObject }) {
    const challengePayload = verifyToken(
      challenge,
      this.#sessionSecret(),
      "challenge",
      this.now(),
    );
    const clientDataHash = sha256(Buffer.from(challenge, "utf8"));
    const verified = verifyAttestation({
      keyID,
      attestationObject: decodeBase64(attestationObject, "attestationObject"),
      clientDataHash,
      appID: this.#appID(),
      environment: this.environment.APP_ATTEST_ENVIRONMENT || "production",
    });
    const id = installationID(keyID);
    await this.store.createInstallation(id, {
      keyID,
      publicKey: verified.publicKey,
      environment: verified.environment,
      challengeIssuedAt: challengePayload.iat,
    });
    return this.#session(id);
  }

  async assert({ keyID, challenge, assertion }) {
    verifyToken(challenge, this.#sessionSecret(), "challenge", this.now());
    const id = installationID(keyID);
    const installation = await this.store.installation(id);
    if (!installation) {
      throw new SecurityError("Unknown App Attest key", {
        status: 404,
        code: "unknown_key",
      });
    }
    if (installation.disabled) throw new SecurityError("This installation is disabled");

    const result = verifyAssertion({
      assertion: decodeBase64(assertion, "assertion"),
      clientDataHash: sha256(Buffer.from(challenge, "utf8")),
      publicKey: installation.publicKey,
      appID: this.#appID(),
    });
    await this.store.advanceAssertionCounter(id, result.counter);
    return this.#session(id);
  }

  async authorizeAnalysis(request) {
    const authorization = request.headers.authorization || "";
    const appAttestToken = authorization.startsWith("AppAttest ")
      ? authorization.slice("AppAttest ".length)
      : null;

    if (appAttestToken) {
      const payload = verifyToken(
        appAttestToken,
        this.#sessionSecret(),
        "session",
        this.now(),
      );
      await this.store.consumeInstallationQuota(payload.sub, this.#installationPolicy(), this.now());
      await this.store.consumeGlobalQuota(this.#globalPolicy(), this.now());
      return { mode: "app-attest", installationID: payload.sub };
    }

    if (!this.#legacyAuthorized(authorization)) {
      throw new SecurityError("Unauthorized");
    }
    if (this.environment.ALLOW_LEGACY_TOKEN === "false") {
      throw new SecurityError("This version of Later must be updated", {
        status: 426,
        code: "update_required",
      });
    }

    if (this.configured) {
      const identity = legacyIdentity(request);
      const id = keyedHash(identity, this.#sessionSecret());
      await this.store.consumeLegacyQuota(id, this.#legacyPolicy(), this.now());
      await this.store.consumeGlobalQuota(this.#legacyGlobalPolicy(), this.now());
    }
    return { mode: "legacy" };
  }

  #session(id) {
    const now = this.now();
    const expiresAt = now + numberSetting(
      this.environment.APP_ATTEST_SESSION_TTL_SECONDS,
      7 * 24 * 60 * 60,
    ) * 1000;
    return {
      token: signToken({
        type: "session",
        sub: id,
        iat: Math.floor(now / 1000),
        exp: Math.floor(expiresAt / 1000),
      }, this.#sessionSecret()),
      expiresAt,
    };
  }

  #legacyAuthorized(authorization) {
    const expected = this.environment.LATER_API_TOKEN?.trim();
    if (!expected) return true;
    const actual = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
    return safeEqual(Buffer.from(expected), Buffer.from(actual));
  }

  #sessionSecret(required = true) {
    const value = this.environment.LATER_SESSION_SECRET?.trim();
    if (!value && required) {
      throw new SecurityError("App Attest is not configured", {
        status: 503,
        code: "attest_unavailable",
      });
    }
    if (value && Buffer.byteLength(value) < 32) {
      throw new SecurityError("App Attest session secret is too short", {
        status: 503,
        code: "attest_misconfigured",
      });
    }
    return value;
  }

  #appID() {
    const teamID = this.environment.APP_ATTEST_TEAM_ID?.trim();
    const bundleID = this.environment.APP_ATTEST_BUNDLE_ID?.trim();
    if (!teamID || !bundleID) {
      throw new SecurityError("App Attest identity is not configured", {
        status: 503,
        code: "attest_misconfigured",
      });
    }
    return `${teamID}.${bundleID}`;
  }

  #installationPolicy() {
    return {
      dailyLimit: numberSetting(this.environment.ANALYSIS_DAILY_LIMIT, 300),
      burstLimit: numberSetting(this.environment.ANALYSIS_BURST_LIMIT, 120),
      burstWindowMs: numberSetting(this.environment.ANALYSIS_BURST_WINDOW_SECONDS, 300) * 1000,
    };
  }

  #legacyPolicy() {
    return {
      dailyLimit: numberSetting(this.environment.LEGACY_ANALYSIS_DAILY_LIMIT, 300),
      burstLimit: numberSetting(this.environment.LEGACY_ANALYSIS_BURST_LIMIT, 120),
      burstWindowMs: numberSetting(this.environment.ANALYSIS_BURST_WINDOW_SECONDS, 300) * 1000,
    };
  }

  #globalPolicy() {
    return { dailyLimit: numberSetting(this.environment.ANALYSIS_GLOBAL_DAILY_LIMIT, 20_000) };
  }

  #legacyGlobalPolicy() {
    return { dailyLimit: numberSetting(this.environment.LEGACY_GLOBAL_DAILY_LIMIT, 5_000) };
  }
}

export function verifyAttestation({
  keyID,
  attestationObject,
  clientDataHash,
  appID,
  environment = "production",
}) {
  let object;
  try { object = decode(attestationObject); } catch {
    throw invalidAttestation("Malformed attestation object");
  }
  if (field(object, "fmt") !== "apple-appattest") {
    throw invalidAttestation("Unexpected attestation format");
  }
  const authData = bufferField(object, "authData");
  const statement = field(object, "attStmt");
  const certificates = field(statement, "x5c");
  if (!Array.isArray(certificates) || certificates.length < 2) {
    throw invalidAttestation("Incomplete Apple certificate chain");
  }

  let leaf;
  let intermediate;
  try {
    leaf = new X509Certificate(Buffer.from(certificates[0]));
    intermediate = new X509Certificate(Buffer.from(certificates[1]));
  } catch {
    throw invalidAttestation("Invalid Apple certificate chain");
  }
  validateCertificateChain(leaf, intermediate);

  const expectedNonce = sha256(Buffer.concat([authData, clientDataHash]));
  const certificateNonce = appAttestNonce(leaf.raw);
  if (!safeEqual(expectedNonce, certificateNonce)) {
    throw invalidAttestation("Attestation nonce does not match the request");
  }

  const parsed = parseAuthenticatorData(authData);
  verifyRPID(parsed.rpIDHash, appID);
  if (parsed.counter !== 0) throw invalidAttestation("Invalid attestation counter");
  const expectedAAGUID = environment === "development"
    ? Buffer.from("appattestdevelop", "ascii")
    : Buffer.concat([Buffer.from("appattest", "ascii"), Buffer.alloc(7)]);
  if (!safeEqual(parsed.aaguid, expectedAAGUID)) {
    throw invalidAttestation("Unexpected App Attest environment");
  }

  const keyIDBytes = decodeBase64(keyID, "keyID");
  if (!safeEqual(parsed.credentialID, keyIDBytes)) {
    throw invalidAttestation("Credential ID does not match the App Attest key");
  }
  const jwk = leaf.publicKey.export({ format: "jwk" });
  const publicPoint = Buffer.concat([
    Buffer.from([0x04]),
    Buffer.from(jwk.x, "base64url"),
    Buffer.from(jwk.y, "base64url"),
  ]);
  if (!safeEqual(sha256(publicPoint), keyIDBytes)) {
    throw invalidAttestation("Certificate public key does not match the key ID");
  }

  return {
    publicKey: leaf.publicKey.export({ type: "spki", format: "pem" }).toString(),
    environment,
  };
}

export function verifyAssertion({ assertion, clientDataHash, publicKey, appID }) {
  let object;
  try { object = decode(assertion); } catch {
    throw invalidAttestation("Malformed assertion object");
  }
  const authenticatorData = bufferField(object, "authenticatorData");
  const signature = bufferField(object, "signature");
  const parsed = parseAuthenticatorData(authenticatorData, false);
  verifyRPID(parsed.rpIDHash, appID);
  if (parsed.counter <= 0) throw invalidAttestation("Invalid assertion counter");

  const signedData = Buffer.concat([authenticatorData, clientDataHash]);
  let valid = false;
  try {
    valid = verifySignature("sha256", signedData, createPublicKey(publicKey), signature);
  } catch {}
  if (!valid) throw invalidAttestation("Invalid App Attest assertion signature");
  return { counter: parsed.counter };
}

export function signToken(payload, secret) {
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const signature = createHmac("sha256", secret).update(encoded).digest("base64url");
  return `${encoded}.${signature}`;
}

export function verifyToken(token, secret, expectedType, now = Date.now()) {
  const [encoded, signature, extra] = String(token || "").split(".");
  if (!encoded || !signature || extra) throw new SecurityError("Invalid security token");
  const expected = createHmac("sha256", secret).update(encoded).digest();
  if (!safeEqual(expected, Buffer.from(signature, "base64url"))) {
    throw new SecurityError("Invalid security token");
  }
  let payload;
  try { payload = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")); } catch {
    throw new SecurityError("Invalid security token");
  }
  if (payload.type !== expectedType || !Number.isFinite(payload.exp)) {
    throw new SecurityError("Invalid security token");
  }
  if (payload.exp * 1000 <= now) {
    throw new SecurityError("Security token expired", { code: "token_expired" });
  }
  return payload;
}

function validateCertificateChain(leaf, intermediate) {
  const now = new Date();
  for (const certificate of [leaf, intermediate, appleRoot]) {
    if (now < new Date(certificate.validFrom) || now > new Date(certificate.validTo)) {
      throw invalidAttestation("Expired App Attest certificate");
    }
  }
  if (leaf.issuer !== intermediate.subject || !leaf.verify(intermediate.publicKey)) {
    throw invalidAttestation("Untrusted App Attest leaf certificate");
  }
  if (intermediate.issuer !== appleRoot.subject || !intermediate.verify(appleRoot.publicKey)) {
    throw invalidAttestation("Untrusted App Attest certificate chain");
  }
  const expectedFingerprint = "1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32";
  if (appleRoot.fingerprint256 !== expectedFingerprint) {
    throw invalidAttestation("Unexpected Apple App Attestation root certificate");
  }
}

function appAttestNonce(certificateDER) {
  const oidIndex = certificateDER.indexOf(nonceExtensionOID);
  if (oidIndex < 0) throw invalidAttestation("Missing App Attest nonce extension");
  let offset = oidIndex + nonceExtensionOID.length;
  let extension = readDER(certificateDER, offset);
  if (extension.tag === 0x01) {
    offset = extension.end;
    extension = readDER(certificateDER, offset);
  }
  if (extension.tag !== 0x04) throw invalidAttestation("Malformed App Attest nonce extension");
  const nonce = findOctetString(extension.value, 32);
  if (!nonce) throw invalidAttestation("Malformed App Attest nonce value");
  return nonce;
}

function findOctetString(der, expectedLength) {
  let offset = 0;
  while (offset < der.length) {
    const value = readDER(der, offset);
    if (value.tag === 0x04 && value.value.length === expectedLength) return value.value;
    if ((value.tag & 0x20) !== 0 || (value.tag & 0xc0) === 0x80) {
      const nested = findOctetString(value.value, expectedLength);
      if (nested) return nested;
    }
    offset = value.end;
  }
  return null;
}

function readDER(data, offset) {
  if (offset + 2 > data.length) throw invalidAttestation("Malformed certificate extension");
  const tag = data[offset];
  let length = data[offset + 1];
  let headerLength = 2;
  if ((length & 0x80) !== 0) {
    const bytes = length & 0x7f;
    if (bytes === 0 || bytes > 4 || offset + 2 + bytes > data.length) {
      throw invalidAttestation("Malformed certificate extension length");
    }
    length = 0;
    for (let index = 0; index < bytes; index += 1) {
      length = (length * 256) + data[offset + 2 + index];
    }
    headerLength += bytes;
  }
  const start = offset + headerLength;
  const end = start + length;
  if (end > data.length) throw invalidAttestation("Malformed certificate extension value");
  return { tag, value: data.subarray(start, end), end };
}

function parseAuthenticatorData(data, requireCredential = true) {
  if (data.length < 37) throw invalidAttestation("Authenticator data is too short");
  const result = {
    rpIDHash: data.subarray(0, 32),
    flags: data[32],
    counter: data.readUInt32BE(33),
  };
  if (!requireCredential) return result;
  if ((result.flags & 0x40) === 0 || data.length < 55) {
    throw invalidAttestation("Attested credential data is missing");
  }
  result.aaguid = data.subarray(37, 53);
  const credentialLength = data.readUInt16BE(53);
  if (data.length < 55 + credentialLength) {
    throw invalidAttestation("Credential ID is truncated");
  }
  result.credentialID = data.subarray(55, 55 + credentialLength);
  return result;
}

function verifyRPID(actual, appID) {
  if (!safeEqual(actual, sha256(Buffer.from(appID, "utf8")))) {
    throw invalidAttestation("App identity does not match Later");
  }
}

function field(value, name) {
  return value instanceof Map ? value.get(name) : value?.[name];
}

function bufferField(value, name) {
  const result = field(value, name);
  if (!(result instanceof Uint8Array)) throw invalidAttestation(`Missing ${name}`);
  return Buffer.from(result);
}

function decodeBase64(value, name) {
  if (typeof value !== "string" || !value) throw invalidAttestation(`Missing ${name}`);
  try {
    const result = Buffer.from(value, value.includes("-") || value.includes("_")
      ? "base64url"
      : "base64");
    if (!result.length) throw new Error();
    return result;
  } catch {
    throw invalidAttestation(`Invalid ${name}`);
  }
}

function invalidAttestation(message) {
  return new SecurityError(message, { status: 401, code: "invalid_attestation" });
}

function installationID(keyID) {
  return createHash("sha256").update(keyID).digest("hex");
}

function legacyIdentity(request) {
  const installID = request.headers["x-later-install-id"];
  if (typeof installID === "string" && /^[0-9a-f-]{36}$/i.test(installID)) {
    return `install:${installID.toLowerCase()}`;
  }
  const pushToken = request.headers["x-later-push-token"];
  if (typeof pushToken === "string" && /^[a-f\d]{64}$/i.test(pushToken)) {
    return `push:${pushToken.toLowerCase()}`;
  }
  const forwarded = String(request.headers["x-forwarded-for"] || "").split(",")[0].trim();
  return `network:${forwarded || request.socket?.remoteAddress || "unknown"}`;
}

function keyedHash(value, secret) {
  return createHmac("sha256", secret).update(value).digest("hex");
}

function sha256(value) {
  return createHash("sha256").update(value).digest();
}

function safeEqual(left, right) {
  return left.length === right.length && timingSafeEqual(left, right);
}

function utcDay(now) {
  return new Date(now).toISOString().slice(0, 10);
}

function secondsUntilTomorrow(now) {
  const date = new Date(now);
  const tomorrow = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate() + 1);
  return Math.max(1, Math.ceil((tomorrow - now) / 1000));
}

function numberSetting(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
