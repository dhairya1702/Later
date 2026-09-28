import { createPrivateKey, sign } from "node:crypto";
import { connect } from "node:http2";

const productionHost = "api.push.apple.com";
const sandboxHost = "api.sandbox.push.apple.com";

export function apnsConfigured(environment = process.env) {
  return Boolean(
    environment.APNS_KEY_ID?.trim()
      && environment.APNS_TEAM_ID?.trim()
      && environment.APNS_TOPIC?.trim()
      && environment.APNS_PRIVATE_KEY?.trim(),
  );
}

export function makeProviderToken(environment = process.env, now = Date.now()) {
  const keyID = environment.APNS_KEY_ID?.trim();
  const teamID = environment.APNS_TEAM_ID?.trim();
  const privateKey = environment.APNS_PRIVATE_KEY?.replaceAll("\\n", "\n").trim();
  if (!keyID || !teamID || !privateKey) throw new Error("APNs is not configured");

  const encodedHeader = base64url(JSON.stringify({ alg: "ES256", kid: keyID }));
  const encodedClaims = base64url(JSON.stringify({
    iss: teamID,
    iat: Math.floor(now / 1000),
  }));
  const unsignedToken = `${encodedHeader}.${encodedClaims}`;
  const signature = sign("sha256", Buffer.from(unsignedToken), {
    key: createPrivateKey(privateKey),
    dsaEncoding: "ieee-p1363",
  });
  return `${unsignedToken}.${base64url(signature)}`;
}

export async function sendAnalysisCompletePush({
  deviceToken,
  environment,
  itemID,
  title,
}, configuration = process.env) {
  if (!apnsConfigured(configuration) || !/^[a-f\d]{64}$/i.test(deviceToken || "")) {
    return false;
  }

  const host = environment === "sandbox" ? sandboxHost : productionHost;
  const payload = JSON.stringify({
    aps: {
      alert: { title: "Saved to Later", body: title },
      sound: "default",
      category: "later.item",
    },
    itemID,
    itemIDs: [itemID],
  });

  const client = connect(`https://${host}`);
  try {
    await new Promise((resolve, reject) => {
      const request = client.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        authorization: `bearer ${makeProviderToken(configuration)}`,
        "apns-topic": configuration.APNS_TOPIC.trim(),
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": "0",
      });
      let status = 0;
      const chunks = [];
      request.setEncoding("utf8");
      request.on("response", (headers) => { status = Number(headers[":status"] || 0); });
      request.on("data", (chunk) => chunks.push(chunk));
      request.on("error", reject);
      request.on("end", () => {
        if (status === 200) return resolve();
        let reason = "unknown error";
        try { reason = JSON.parse(chunks.join("")).reason || reason; } catch {}
        reject(new Error(`APNs rejected notification (${status}): ${reason}`));
      });
      request.end(payload);
    });
    return true;
  } finally {
    client.close();
  }
}

function base64url(value) {
  return Buffer.from(value).toString("base64url");
}
