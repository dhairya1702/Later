import assert from "node:assert/strict";
import test from "node:test";
import {
  configuredModel,
  configuredProvider,
  parseOutput,
  toVertexSchema,
  validateAnalysis,
} from "../analyze.mjs";

const validAnalysis = {
  title: "Dinner reservation",
  summary: "Reservation at Marlow for Friday.",
  suggestedAction: "Add the reservation to your calendar.",
  visibleText: "Marlow Friday 7:00 PM",
  category: "eat",
  kind: "food",
  surface: "unknown",
  sourceApp: "unknown",
  confidence: 0.93,
  needsReview: false,
  evidence: ["Marlow", "Friday 7:00 PM"],
  actionableEntities: [],
  media: null,
  productDetails: null,
  facts: {
    dateText: "Friday",
    timeText: "7:00 PM",
    dateRole: "reservation",
    location: "Marlow",
    priceText: null,
    currency: null,
    url: null,
    couponCode: null,
    discountText: null
  }
};

test("Gemini structured output preserves the app response contract", () => {
  const response = {
    candidates: [{
      content: { parts: [{ text: JSON.stringify(validAnalysis) }] },
      finishReason: "STOP"
    }]
  };
  assert.deepEqual(parseOutput(response), validAnalysis);
});

test("Gemini fenced JSON is accepted defensively", () => {
  const response = {
    candidates: [{ content: { parts: [{ text: `\`\`\`json\n${JSON.stringify(validAnalysis)}\n\`\`\`` }] } }]
  };
  assert.deepEqual(parseOutput(response), validAnalysis);
});

test("invalid model output is rejected before reaching the phone", () => {
  assert.throws(
    () => validateAnalysis({ ...validAnalysis, category: "madeUp" }),
    /unsupported value/,
  );
  const { facts, ...missingFacts } = validAnalysis;
  assert.throws(() => validateAnalysis(missingFacts), /facts is required/);
});

test("Vertex schema converts nullable JSON schema values", () => {
  assert.deepEqual(
    toVertexSchema({ type: ["string", "null"] }),
    { type: "STRING", nullable: true },
  );
  assert.deepEqual(
    toVertexSchema({ anyOf: [{ type: "null" }, { type: "object", properties: {} }] }),
    { type: "OBJECT", properties: {}, propertyOrdering: [], nullable: true },
  );
});

test("Vertex is selected when its project is configured", () => {
  const previousProvider = process.env.AI_PROVIDER;
  const previousProject = process.env.GOOGLE_CLOUD_PROJECT;
  delete process.env.AI_PROVIDER;
  process.env.GOOGLE_CLOUD_PROJECT = "later-test";
  try {
    assert.equal(configuredProvider(), "vertex");
    assert.equal(configuredModel(), "gemini-2.5-flash-lite");
  } finally {
    if (previousProvider == null) delete process.env.AI_PROVIDER;
    else process.env.AI_PROVIDER = previousProvider;
    if (previousProject == null) delete process.env.GOOGLE_CLOUD_PROJECT;
    else process.env.GOOGLE_CLOUD_PROJECT = previousProject;
  }
});
