#!/usr/bin/env node

import { createServer } from "node:http";
import process from "node:process";
import {
  analyzeImageBytes,
  configuredModel,
  configuredProvider,
  loadLocalEnvironment,
  parseOutput,
  requireProviderConfiguration,
} from "./analyze.mjs";
import { sendAnalysisCompletePush } from "./apns.mjs";
import { BackendSecurity, SecurityError } from "./security.mjs";

const host = "0.0.0.0";
const port = Number(process.env.PORT || process.env.LATER_VISION_PORT || 8080);
const maxBytes = 12 * 1024 * 1024;

await loadLocalEnvironment();
requireProviderConfiguration();
const security = new BackendSecurity();

const server = createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health") {
      return sendJSON(response, 200, {
        ok: true,
        provider: configuredProvider(),
        model: configuredModel(),
        appAttest: security.configured,
      });
    }

    if (request.method === "POST" && request.url === "/auth/challenge") {
      return sendJSON(response, 200, { challenge: security.makeChallenge() });
    }

    if (request.method === "POST" && request.url === "/auth/attest") {
      const payload = await readJSON(request);
      return sendJSON(response, 200, await security.attest(payload));
    }

    if (request.method === "POST" && request.url === "/auth/assert") {
      const payload = await readJSON(request);
      return sendJSON(response, 200, await security.assert(payload));
    }

    if (request.method !== "POST" || request.url !== "/analyze") {
      return sendJSON(response, 404, { error: "Not found" });
    }

    const mimeType = (request.headers["content-type"] || "").split(";")[0];
    if (!["image/jpeg", "image/png", "image/webp"].includes(mimeType)) {
      return sendJSON(response, 415, { error: "Send a JPEG, PNG, or WebP image body" });
    }
    await security.authorizeAnalysis(request);

    const bytes = await readBody(request);
    const startedAt = Date.now();
    const analysis = await withRetry(async () => {
      const upstream = await analyzeImageBytes(bytes, mimeType);
      return parseOutput(upstream);
    });
    console.log(`Analysis completed (${Date.now() - startedAt}ms)`);
    let pushSent = false;
    const deviceToken = request.headers["x-later-push-token"];
    const itemID = request.headers["x-later-item-id"];
    if (typeof deviceToken === "string" && typeof itemID === "string") {
      try {
        pushSent = await sendAnalysisCompletePush({
          deviceToken,
          environment: request.headers["x-later-apns-environment"],
          itemID,
          title: analysis.title,
        });
      } catch (error) {
        console.error(`Push delivery failed: ${operationalErrorCode(error)}`);
      }
    }
    return sendJSON(response, 200, { analysis }, {
      "X-Later-Push-Sent": pushSent ? "true" : "false",
    });
  } catch (error) {
    console.error(`Request failed: ${operationalErrorCode(error)}`);
    const status = error instanceof SecurityError
      ? error.status
      : error.code === "PAYLOAD_TOO_LARGE"
        ? 413
        : error.code === "INVALID_JSON"
          ? 400
          : 502;
    const headers = error.retryAfter ? { "Retry-After": String(error.retryAfter) } : {};
    return sendJSON(response, status, {
      error: error.message,
      ...(error instanceof SecurityError ? { code: error.code } : {}),
    }, headers);
  }
});

server.listen(port, host, () => {
  console.log(`Later vision bridge listening on http://${host}:${port}`);
});

async function readBody(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > maxBytes) {
      const error = new Error("Image exceeds the 12 MB limit");
      error.code = "PAYLOAD_TOO_LARGE";
      throw error;
    }
    chunks.push(chunk);
  }
  if (length === 0) throw new Error("Image body is empty");
  return Buffer.concat(chunks);
}

async function readJSON(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 512 * 1024) {
      const error = new Error("Security request exceeds the 512 KB limit");
      error.code = "PAYLOAD_TOO_LARGE";
      throw error;
    }
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    const error = new Error("Invalid JSON request");
    error.code = "INVALID_JSON";
    throw error;
  }
}

async function withRetry(operation) {
  let lastError;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  throw lastError;
}

function sendJSON(response, status, value, extraHeaders = {}) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    ...extraHeaders,
  });
  response.end(body);
}

function operationalErrorCode(error) {
  if (error instanceof SecurityError) return error.code;
  if (typeof error?.code === "string") return error.code;
  return error?.name || "unknown_error";
}
