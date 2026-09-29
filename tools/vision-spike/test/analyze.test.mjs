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
  sourceContext: null,
  likelyAccidental: false,
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

test("Reddit communities and LinkedIn are accepted as source metadata", () => {
  const reddit = { ...validAnalysis, sourceApp: "reddit", sourceContext: "r/AskReddit" };
  assert.equal(validateAnalysis(reddit).sourceContext, "r/AskReddit");

  const linkedin = { ...validAnalysis, sourceApp: "linkedin", sourceContext: null };
  assert.equal(validateAnalysis(linkedin).sourceApp, "linkedin");
});

test("LinkedIn job listings have a dedicated content type", () => {
  const job = {
    ...validAnalysis,
    category: "remember",
    kind: "job",
    sourceApp: "linkedin",
    sourceContext: null,
  };
  assert.equal(validateAnalysis(job).kind, "job");
});

test("plain iPhone Home Screens are normalized as accidental", () => {
  const homeScreen = validateAnalysis({
    ...validAnalysis,
    category: "photo",
    kind: "photo",
    surface: "homeScreen",
    likelyAccidental: false,
    needsReview: true,
  });
  assert.equal(homeScreen.category, "other");
  assert.equal(homeScreen.kind, "other");
  assert.equal(homeScreen.likelyAccidental, true);
  assert.equal(homeScreen.needsReview, false);
});

test("the fixed taxonomy rejects the removed inspiration category", () => {
  assert.throws(
    () => validateAnalysis({ ...validAnalysis, category: "inspire" }),
    /unsupported value/,
  );
});

test("boardingPass remains the compatible broad Travel kind", () => {
  const travel = validateAnalysis({
    ...validAnalysis,
    category: "go",
    kind: "boardingPass",
    facts: { ...validAnalysis.facts, dateRole: "travel" },
  });
  assert.equal(travel.kind, "boardingPass");
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
