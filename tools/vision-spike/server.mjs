#!/usr/bin/env node

import { createServer } from "node:http";
import process from "node:process";
import {
  analyzeImageBytes,
  loadLocalEnvironment,
  parseOutput,
} from "./analyze.mjs";

const host = "0.0.0.0";
const port = Number(process.env.LATER_VISION_PORT || 8787);
const maxBytes = 12 * 1024 * 1024;

await loadLocalEnvironment();

if (!process.env.OPENAI_API_KEY || process.env.OPENAI_API_KEY.includes("replace_with")) {
  console.error("Missing OPENAI_API_KEY in .env.local");
  process.exit(1);
}

const server = createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/health") {
      return sendJSON(response, 200, {
        ok: true,
        model: process.env.OPENAI_MODEL || "gpt-6-luna",
      });
    }

    if (request.method !== "POST" || request.url !== "/analyze") {
      return sendJSON(response, 404, { error: "Not found" });
    }

    const mimeType = (request.headers["content-type"] || "").split(";")[0];
    if (!["image/jpeg", "image/png", "image/webp"].includes(mimeType)) {
      return sendJSON(response, 415, { error: "Send a JPEG, PNG, or WebP image body" });
    }

    const bytes = await readBody(request);
    const startedAt = Date.now();
    const upstream = await withRetry(() => analyzeImageBytes(bytes, mimeType));
    const analysis = parseOutput(upstream);
    console.log(`${analysis.category}/${analysis.kind} ${analysis.title} (${Date.now() - startedAt}ms)`);
    return sendJSON(response, 200, { analysis });
  } catch (error) {
    console.error(error.message);
    return sendJSON(response, 502, { error: error.message });
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
    if (length > maxBytes) throw new Error("Image exceeds the 12 MB local limit");
    chunks.push(chunk);
  }
  if (length === 0) throw new Error("Image body is empty");
  return Buffer.concat(chunks);
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

function sendJSON(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  response.end(body);
}
