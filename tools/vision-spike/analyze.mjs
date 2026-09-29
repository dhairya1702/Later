#!/usr/bin/env node

import { readFile, readdir, mkdir, writeFile } from "node:fs/promises";
import { basename, dirname, extname, join, resolve } from "node:path";
import process from "node:process";
import { GoogleAuth } from "google-auth-library";

const ROOT = resolve(dirname(new URL(import.meta.url).pathname), "../..");
const DEFAULT_INPUT = join(ROOT, "tools/vision-spike/screenshots");
const RESULTS_DIR = join(ROOT, "tools/vision-spike/results");
const SUPPORTED_EXTENSIONS = new Set([".jpg", ".jpeg", ".png", ".webp"]);

const categories = [
  "watch", "listen", "eat", "go", "buy", "read", "doItem", "remember",
  "offer", "photo", "other",
];

const kinds = [
  "concert", "music", "shopping", "food", "movie", "show", "activity",
  "task", "job", "book", "article", "place", "event", "information", "offer",
  "photo", "document", "meme",
  "chat", "story", "email", "boardingPass", "app", "map", "socialPost",
  "comments", "lockScreen", "other",
];

const surfaces = [
  "chat", "story", "email", "boardingPass", "appStore", "map",
  "redditPost", "comments", "homeScreen", "lockScreen", "unknown",
];

const sourceApps = [
  "iMessage", "whatsapp", "snapchat", "appleMail", "gmail", "outlook",
  "reddit", "appStore", "appleMaps", "googleMaps", "instagram", "youtube",
  "linkedin", "tiktok", "appleMusic", "spotify", "amazon", "flipkart",
  "facebookMarketplace", "ebay", "unknown",
];

const actionableEntityTypes = ["phone", "email", "url", "address", "couponCode"];

const nullableString = { type: ["string", "null"] };

const schema = {
  type: "object",
  additionalProperties: false,
  properties: {
    title: { type: "string" },
    summary: { type: "string" },
    suggestedAction: { type: "string" },
    visibleText: { type: "string" },
    category: { type: "string", enum: categories },
    kind: { type: "string", enum: kinds },
    surface: { type: "string", enum: surfaces },
    sourceApp: { type: "string", enum: sourceApps },
    sourceContext: nullableString,
    likelyAccidental: { type: "boolean" },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    needsReview: { type: "boolean" },
    evidence: { type: "array", items: { type: "string" } },
    actionableEntities: {
      type: "array",
      maxItems: 5,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          type: { type: "string", enum: actionableEntityTypes },
          value: { type: "string" },
          confidence: { type: "number", minimum: 0, maximum: 1 },
          evidence: { type: "string" },
        },
        required: ["type", "value", "confidence", "evidence"],
      },
    },
    media: {
      anyOf: [
        { type: "null" },
        {
          type: "object",
          additionalProperties: false,
          properties: {
            type: { type: "string", enum: ["song", "podcast"] },
            title: { type: "string" },
            creator: { type: "string" },
            sourceService: {
              type: "string",
              enum: ["appleMusic", "spotify", "youtube", "other", "unknown"],
            },
            confidence: { type: "number", minimum: 0, maximum: 1 },
            evidence: { type: "array", minItems: 1, maxItems: 4, items: { type: "string" } },
          },
          required: ["type", "title", "creator", "sourceService", "confidence", "evidence"],
        },
      ],
    },
    productDetails: {
      anyOf: [
        { type: "null" },
        {
          type: "object",
          additionalProperties: false,
          properties: {
            name: { type: "string" },
            brand: nullableString,
            model: nullableString,
            variant: nullableString,
            currentPrice: nullableString,
            originalPrice: nullableString,
            discount: nullableString,
            seller: nullableString,
            condition: nullableString,
            negotiable: nullableString,
            rating: nullableString,
            reviewCount: nullableString,
            delivery: nullableString,
            availability: nullableString,
            fulfillment: nullableString,
            location: nullableString,
            confidence: { type: "number", minimum: 0, maximum: 1 },
            evidence: { type: "array", minItems: 1, maxItems: 6, items: { type: "string" } },
          },
          required: [
            "name", "brand", "model", "variant", "currentPrice", "originalPrice",
            "discount", "seller", "condition", "negotiable", "rating", "reviewCount", "delivery",
            "availability", "fulfillment", "location", "confidence", "evidence",
          ],
        },
      ],
    },
    facts: {
      type: "object",
      additionalProperties: false,
      properties: {
        dateText: nullableString,
        timeText: nullableString,
        dateRole: {
          type: ["string", "null"],
          enum: ["event", "expiration", "deadline", "reservation", "delivery", "travel", null],
        },
        location: nullableString,
        priceText: nullableString,
        currency: nullableString,
        url: nullableString,
        couponCode: nullableString,
        discountText: nullableString,
      },
      required: [
        "dateText", "timeText", "dateRole", "location", "priceText", "currency", "url",
        "couponCode", "discountText",
      ],
    },
  },
  required: [
    "title", "summary", "suggestedAction", "visibleText", "category", "kind",
    "surface", "sourceApp", "sourceContext", "likelyAccidental", "confidence", "needsReview", "evidence",
    "actionableEntities", "media", "productDetails", "facts",
  ],
};

const instructions = `
You analyze iPhone screenshots for Later, an app that recovers why a person saved a screenshot.

Interpret the entire screenshot: app chrome, UI hierarchy, imagery, visible text, buttons, and relationships between them. Identify the likely source app and screen surface, then infer the user's most likely intent. Category is the user's intent; kind is the saved subject or screen type. A chat or social post can still contain something to eat, buy, watch, read, or visit.

Choose only from the supplied enum values. Write a short useful title for a card in the app. Use "other" and needsReview=true when the intent is genuinely unclear. Confidence represents confidence in the complete classification, not confidence that text is readable.

sourceApp identifies the app or platform whose UI is visibly shown; use linkedin for recognizable LinkedIn screenshots. sourceContext is optional, visibly supported context about that source. For Reddit, return the exact community name normalized as r/CommunityName when it is visible. Never guess a community from the post topic, username, or content. Return null for sourceContext when the community is absent or ambiguous, and for non-Reddit sources.

For a LinkedIn job listing or job-posting screen, always use sourceApp=linkedin and kind=job. Use category=remember for a saved job listing unless the screenshot contains a clear application task or deadline, in which case use doItem. A job title, employer, salary, workplace, and employment details are job information, not productDetails. Never classify a job listing as shopping or buy.

For a plain iPhone Home Screen showing a grid of app icons, always use surface=homeScreen, category=other, kind=other, likelyAccidental=true, and needsReview=false. Never interpret the word "home" in Home Screen as interior design, decor, architecture, or inspiration.

likelyAccidental is true only when the image is very likely an unintended screenshot: a plain iPhone Home Screen; a plain Lock Screen containing only ordinary clock/date/status chrome; or an actively ringing iPhone alarm screen showing controls such as Snooze and Stop. Alarm captures made while dismissing or snoozing an alarm are likely accidental, not information to remember. Be conservative otherwise. Return false for Lock Screens with meaningful notifications, music or media, navigation, live activities, useful information, or a wallpaper/photo that appears to be the subject. Never infer accidental merely because surface is lockScreen.

Category rules: use offer when the main saved value is a redeemable promotion, coupon, discount code, or limited-time deal. Use buy for a specific product the user may want to purchase, not for a coupon merely because redemption involves a purchase. Use eat for a restaurant, dish, or recipe; use go for a destination, venue, trip, or event; use photo for an image whose main value is visual; use remember for information without a clearer actionable intent. There is no inspiration category.

The legacy kind value boardingPass is the broad Travel kind. Use it for boarding passes, flight details, itineraries, hotel reservations, and train or bus tickets. Pair it with category=go. It is not limited to a literal boarding pass.

Facts must be visibly supported by the screenshot. Never invent a date, price, address, URL, coupon, or location from world knowledge. dateText/timeText are only for a date or time meaningfully attached to the saved subject, and dateRole says why it matters. Never extract status-bar time, screenshot/capture time, chat-message timestamp, last-seen time, post age, upload time, or other app chrome. If a date/time has no event, expiration, deadline, reservation, delivery, or travel role, return dateText, timeText, and dateRole as null. Use null when any fact is absent or ambiguous. Never put incidental UI timestamps in title, summary, or suggestedAction. visibleText should contain the important readable text, not every piece of navigation chrome. Evidence should be 1-4 short visible cues, never hidden chain-of-thought.

Preserve the full meaningful date including its year whenever the year is visible. Never supply a missing year or reinterpret an old date as the next upcoming occurrence. For a multi-day event or validity period, use its clearly stated end date; if the relevant end is ambiguous, return null for dateText/timeText/dateRole.

actionableEntities contains only exact, user-actionable values visibly present in the screenshot: phone numbers, email addresses, web URLs, complete addresses, and coupon codes. Preserve the actual value and include the exact visible text in evidence. A random numeric identifier, flight number, confirmation code, price, date, or order number is not a phone number. Omit uncertain entities instead of guessing. Do not return actions merely because an app button is visible.

media describes a specific song or podcast only when both its title and artist/show creator are visibly supported. Put the exact visible title and creator in evidence. Infer sourceService from recognizable app chrome only; otherwise use unknown. Return null for albums, playlists, generic music imagery, uncertain lock screens, videos that are not clearly songs or podcasts, or whenever exact title/creator confidence is below 0.8. These fields power catalog searches, not a claim that an exact playable recording was resolved.

productDetails describes a specific product or marketplace listing, independent of store or platform. Return it only for a clearly identifiable product with confidence at least 0.8; otherwise return null. Ground every populated value in visible screenshot evidence and copy price/discount/rating/delivery wording faithfully. For retail listings prioritize brand, model/variant, current and original price, discount, rating/reviews, delivery, and availability. For peer-to-peer marketplace listings prioritize condition, seller, location, price, negotiability when visibly stated, and pickup/shipping fulfillment. Do not mistake store-wide promotions, cart totals, shipping thresholds, installment examples, sponsored neighboring items, or app chrome for attributes of the primary product. Use null for every absent or ambiguous field.
`.trim();

async function main() {
  await loadLocalEnvironment();

  const argument = process.argv[2];
  if (argument === "--check") {
    requireProviderConfiguration();
    console.log(`Ready. Provider: ${configuredProvider()}`);
    console.log(`Model: ${configuredModel()}`);
    console.log(`Endpoint: ${configuredEndpoint()}`);
    return;
  }

  requireProviderConfiguration();
  const inputPath = resolve(argument || DEFAULT_INPUT);
  const images = await imagePaths(inputPath);

  if (images.length === 0) {
    fail(`No supported screenshots found at ${inputPath}`);
  }

  await mkdir(RESULTS_DIR, { recursive: true });

  for (const imagePath of images) {
    try {
      const startedAt = Date.now();
      const response = await analyze(imagePath);
      const analysis = parseOutput(response);
      const result = {
        file: basename(imagePath),
        provider: configuredProvider(),
        model: response.model || configuredModel(),
        responseId: response.id || null,
        elapsedMilliseconds: Date.now() - startedAt,
        usage: response.usage ?? response.usageMetadata ?? null,
        analysis,
      };
      const resultPath = join(
        RESULTS_DIR,
        `${basename(imagePath, extname(imagePath))}.json`,
      );
      await writeFile(resultPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
      console.log(`\n${basename(imagePath)} → ${analysis.category} / ${analysis.kind}`);
      console.log(`${analysis.title} (${Math.round(analysis.confidence * 100)}%)`);
      console.log(`Saved ${resultPath}`);
    } catch (error) {
      console.error(`\n${basename(imagePath)} failed: ${error.message}`);
      process.exitCode = 1;
    }
  }
}

async function analyze(imagePath) {
  const bytes = await readFile(imagePath);
  const mimeType = mimeTypeFor(imagePath);
  return analyzeImageBytes(bytes, mimeType);
}

export async function analyzeImageBytes(bytes, mimeType) {
  if (configuredProvider() === "vertex") {
    return analyzeImageWithVertex(bytes, mimeType);
  }
  return analyzeImageWithOpenAI(bytes, mimeType);
}

async function analyzeImageWithOpenAI(bytes, mimeType) {
  const imageUrl = `data:${mimeType};base64,${bytes.toString("base64")}`;
  const response = await fetch(responsesEndpoint(), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: configuredModel(),
      store: false,
      reasoning: { effort: "none" },
      instructions,
      input: [{
        role: "user",
        content: [
          { type: "input_text", text: "Analyze this screenshot for Later." },
          { type: "input_image", image_url: imageUrl, detail: "high" },
        ],
      }],
      text: {
        format: {
          type: "json_schema",
          name: "later_screenshot_analysis",
          strict: true,
          schema,
        },
      },
    }),
  });

  const payload = await responsePayload(response);
  if (!response.ok) {
    throw new Error(payload?.error?.message || `OpenAI returned HTTP ${response.status}`);
  }
  return payload;
}

async function analyzeImageWithVertex(bytes, mimeType) {
  const auth = new GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/cloud-platform"],
  });
  const project = process.env.GOOGLE_CLOUD_PROJECT
    || process.env.GCLOUD_PROJECT
    || await auth.getProjectId();
  if (!project) throw new Error("GOOGLE_CLOUD_PROJECT is required for Vertex AI");

  const client = await auth.getClient();
  const response = await client.request({
    url: vertexEndpoint(project),
    method: "POST",
    data: {
      systemInstruction: {
        parts: [{ text: instructions }],
      },
      contents: [{
        role: "user",
        parts: [
          { text: "Analyze this screenshot for Later." },
          {
            inlineData: {
              mimeType,
              data: bytes.toString("base64"),
            },
          },
        ],
      }],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 8192,
        responseMimeType: "application/json",
        responseSchema: toVertexSchema(schema),
      },
    },
  });
  return response.data;
}

async function responsePayload(response) {
  const body = await response.text();
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) return JSON.parse(body);

  if (contentType.includes("text/event-stream") || body.startsWith("event:")) {
    const events = parseServerSentEvents(body);
    for (const event of events.toReversed()) {
      if (event.name === "response.failed") {
        const message = event.data?.response?.error?.message
          || event.data?.error?.message
          || "The upstream model request failed";
        throw new Error(message);
      }
      if (event.data?.response?.output?.length) return event.data.response;
      if (event.data?.output?.length && event.data?.status) return event.data;
    }
    const completed = events.toReversed().find((event) =>
      event.data?.response?.status === "completed" || event.data?.status === "completed"
    );
    const doneText = events.toReversed().find((event) =>
      event.name.includes("output_text.done") && typeof event.data?.text === "string"
    )?.data.text;
    const deltaText = events
      .filter((event) => event.name.includes("output_text.delta"))
      .map((event) => event.data?.delta)
      .filter((delta) => typeof delta === "string")
      .join("");
    const outputText = doneText || deltaText;
    if (completed && outputText) {
      const metadata = completed.data.response || completed.data;
      return {
        ...metadata,
        output: [{
          type: "message",
          content: [{ type: "output_text", text: outputText }],
        }],
      };
    }
    const names = [...new Set(events.map((event) => event.name).filter(Boolean))];
    throw new Error(`Event stream did not include a completed response. Events: ${names.join(", ")}`);
  }

  throw new Error(`Unsupported response type: ${contentType || "unknown"}`);
}

function parseServerSentEvents(body) {
  return body.split(/\r?\n\r?\n/).flatMap((block) => {
    let name = "";
    const dataLines = [];
    for (const line of block.split(/\r?\n/)) {
      if (line.startsWith("event:")) name = line.slice(6).trim();
      if (line.startsWith("data:")) dataLines.push(line.slice(5).trimStart());
    }
    const rawData = dataLines.join("\n");
    if (!rawData || rawData === "[DONE]") return [];
    try {
      return [{ name, data: JSON.parse(rawData) }];
    } catch {
      return [{ name, data: null }];
    }
  });
}

export function parseOutput(response) {
  if (Array.isArray(response.candidates)) {
    const candidate = response.candidates[0];
    const text = candidate?.content?.parts
      ?.map((part) => part.text)
      .filter((part) => typeof part === "string")
      .join("");
    if (!text) {
      const reason = response.promptFeedback?.blockReason
        || candidate?.finishReason
        || "no candidate text";
      throw new Error(`Gemini returned no structured output (${reason})`);
    }
    return validateAnalysis(parseJSONText(text));
  }

  const content = response.output
    ?.filter((item) => item.type === "message")
    .flatMap((item) => item.content || []);
  const refusal = content?.find((item) => item.type === "refusal");
  if (refusal) throw new Error(`Model refused: ${refusal.refusal}`);
  const text = content?.find((item) => item.type === "output_text")?.text;
  if (!text) {
    const shape = response.output?.map((item) => ({
      type: item.type,
      contentTypes: item.content?.map((part) => part.type) || [],
    }));
    throw new Error(
      `No structured output returned (status: ${response.status}, output: ${JSON.stringify(shape || [])})`,
    );
  }
  return validateAnalysis(parseJSONText(text));
}

function parseJSONText(text) {
  const trimmed = text.trim();
  const unfenced = trimmed.startsWith("```")
    ? trimmed.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "")
    : trimmed;
  return JSON.parse(unfenced);
}

export function validateAnalysis(value) {
  validateSchemaValue(value, schema, "analysis");
  if (value.surface === "homeScreen") {
    return {
      ...value,
      category: "other",
      kind: "other",
      likelyAccidental: true,
      needsReview: false,
    };
  }
  return value;
}

function validateSchemaValue(value, definition, path) {
  if (definition.anyOf) {
    const failures = [];
    for (const option of definition.anyOf) {
      try {
        validateSchemaValue(value, option, path);
        return;
      } catch (error) {
        failures.push(error.message);
      }
    }
    throw new Error(`${path} did not match the expected schema: ${failures.join("; ")}`);
  }

  const allowedTypes = Array.isArray(definition.type)
    ? definition.type
    : definition.type ? [definition.type] : [];
  if (value === null) {
    if (allowedTypes.includes("null")) return;
    throw new Error(`${path} must not be null`);
  }

  const actualType = Array.isArray(value) ? "array" : typeof value;
  if (allowedTypes.length && !allowedTypes.includes(actualType)) {
    throw new Error(`${path} must be ${allowedTypes.join(" or ")}`);
  }
  if (definition.enum && !definition.enum.includes(value)) {
    throw new Error(`${path} has an unsupported value`);
  }
  if (actualType === "array") {
    if (definition.minItems != null && value.length < definition.minItems) {
      throw new Error(`${path} has too few items`);
    }
    if (definition.maxItems != null && value.length > definition.maxItems) {
      throw new Error(`${path} has too many items`);
    }
    value.forEach((item, index) => validateSchemaValue(item, definition.items, `${path}[${index}]`));
  }
  if (actualType === "object") {
    for (const key of definition.required || []) {
      if (!(key in value)) throw new Error(`${path}.${key} is required`);
    }
    for (const [key, child] of Object.entries(definition.properties || {})) {
      if (key in value) validateSchemaValue(value[key], child, `${path}.${key}`);
    }
    if (definition.additionalProperties === false) {
      const supported = new Set(Object.keys(definition.properties || {}));
      const extra = Object.keys(value).find((key) => !supported.has(key));
      if (extra) throw new Error(`${path}.${extra} is not supported`);
    }
  }
}

export function toVertexSchema(definition) {
  if (definition.anyOf) {
    const nonNull = definition.anyOf.filter((option) => option.type !== "null");
    const includesNull = nonNull.length !== definition.anyOf.length;
    if (includesNull && nonNull.length === 1) {
      return { ...toVertexSchema(nonNull[0]), nullable: true };
    }
    return { anyOf: nonNull.map(toVertexSchema), ...(includesNull ? { nullable: true } : {}) };
  }

  const rawTypes = Array.isArray(definition.type)
    ? definition.type
    : definition.type ? [definition.type] : [];
  const includesNull = rawTypes.includes("null");
  const type = rawTypes.find((candidate) => candidate !== "null");
  const converted = {};
  if (type) converted.type = type.toUpperCase();
  if (includesNull) converted.nullable = true;
  if (definition.enum) converted.enum = definition.enum.filter((value) => value !== null);
  if (definition.required) converted.required = definition.required;
  if (definition.items) converted.items = toVertexSchema(definition.items);
  if (definition.properties) {
    converted.properties = Object.fromEntries(
      Object.entries(definition.properties).map(([key, value]) => [key, toVertexSchema(value)]),
    );
    converted.propertyOrdering = Object.keys(definition.properties);
  }
  for (const constraint of ["minimum", "maximum", "minItems", "maxItems"]) {
    if (definition[constraint] != null) converted[constraint] = definition[constraint];
  }
  return converted;
}

async function imagePaths(path) {
  const stats = await import("node:fs/promises").then(({ stat }) => stat(path));
  if (stats.isFile()) return SUPPORTED_EXTENSIONS.has(extname(path).toLowerCase()) ? [path] : [];
  if (!stats.isDirectory()) return [];
  const entries = await readdir(path, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isFile() && SUPPORTED_EXTENSIONS.has(extname(entry.name).toLowerCase()))
    .map((entry) => join(path, entry.name))
    .sort();
}

function mimeTypeFor(path) {
  switch (extname(path).toLowerCase()) {
    case ".jpg":
    case ".jpeg": return "image/jpeg";
    case ".png": return "image/png";
    case ".webp": return "image/webp";
    default: throw new Error(`Unsupported image type: ${extname(path)}`);
  }
}

export async function loadLocalEnvironment() {
  try {
    const contents = await readFile(join(ROOT, ".env.local"), "utf8");
    for (const line of contents.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const separator = trimmed.indexOf("=");
      if (separator < 1) continue;
      const key = trimmed.slice(0, separator).trim();
      let value = trimmed.slice(separator + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = value;
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

export function configuredProvider() {
  const explicit = process.env.AI_PROVIDER?.trim().toLowerCase();
  if (explicit) return explicit;
  return process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT ? "vertex" : "openai";
}

export function configuredModel() {
  return configuredProvider() === "vertex"
    ? process.env.GEMINI_MODEL || "gemini-2.5-flash-lite"
    : process.env.OPENAI_MODEL || "gpt-6-luna";
}

export function requireProviderConfiguration() {
  const provider = configuredProvider();
  if (!new Set(["vertex", "openai"]).has(provider)) {
    fail(`Unsupported AI_PROVIDER: ${provider}`);
  }
  if (provider === "openai"
      && (!process.env.OPENAI_API_KEY || process.env.OPENAI_API_KEY.includes("replace_with"))) {
    fail("Missing OPENAI_API_KEY. Copy .env.example to .env.local and add your key.");
  }
}

function configuredEndpoint() {
  if (configuredProvider() === "vertex") {
    const project = process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || "<project>";
    return vertexEndpoint(project);
  }
  return responsesEndpoint();
}

function vertexEndpoint(project) {
  const location = process.env.VERTEX_LOCATION || "us-central1";
  const model = configuredModel();
  return `https://${location}-aiplatform.googleapis.com/v1/projects/${project}`
    + `/locations/${location}/publishers/google/models/${model}:generateContent`;
}

function responsesEndpoint() {
  const baseUrl = (process.env.OPENAI_BASE_URL || "https://api.openai.com/v1")
    .replace(/\/+$/, "");
  return `${baseUrl}/responses`;
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
const modulePath = resolve(new URL(import.meta.url).pathname);
if (invokedPath === modulePath) await main();
