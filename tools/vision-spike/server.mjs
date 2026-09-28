#!/usr/bin/env node

import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
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

const host = "0.0.0.0";
const port = Number(process.env.PORT || process.env.LATER_VISION_PORT || 8080);
const maxBytes = 12 * 1024 * 1024;

await loadLocalEnvironment();
requireProviderConfiguration();

const server = createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health") {
      return sendJSON(response, 200, {
        ok: true,
        provider: configuredProvider(),
        model: configuredModel(),
      });
    }

    if (request.method !== "POST" || request.url !== "/analyze") {
      return sendJSON(response, 404, { error: "Not found" });
    }
    if (!isAuthorized(request)) {
      return sendJSON(response, 401, { error: "Unauthorized" });
    }

    const mimeType = (request.headers["content-type"] || "").split(";")[0];
    if (!["image/jpeg", "image/png", "image/webp"].includes(mimeType)) {
      return sendJSON(response, 415, { error: "Send a JPEG, PNG, or WebP image body" });
    }

    const bytes = await readBody(request);
    const startedAt = Date.now();
    const analysis = await withRetry(async () => {
      const upstream = await analyzeImageBytes(bytes, mimeType);
      return parseOutput(upstream);
    });
    console.log(`${analysis.category}/${analysis.kind} (${Date.now() - startedAt}ms)`);
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
        console.error(`Push delivery failed: ${error.message}`);
      }
    }
    return sendJSON(response, 200, { analysis }, {
      "X-Later-Push-Sent": pushSent ? "true" : "false",
    });
  } catch (error) {
    console.error(error.message);
    const status = error.code === "PAYLOAD_TOO_LARGE" ? 413 : 502;
    return sendJSON(response, status, { error: error.message });
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

function isAuthorized(request) {
  const expected = process.env.LATER_API_TOKEN?.trim();
  if (!expected) return true;
  const header = request.headers.authorization || "";
  const actual = header.startsWith("Bearer ") ? header.slice(7) : "";
  const expectedBytes = Buffer.from(expected);
  const actualBytes = Buffer.from(actual);
  return expectedBytes.length === actualBytes.length
    && timingSafeEqual(expectedBytes, actualBytes);
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
