const FIREBASE_PROJECT_ID = "yokedin-806c2";

// Voice notes used to be capped at 5 MB, which is far too small for call audio.
// Voice and audio now share one ceiling instead of voice having its own, lower
// limit. It stays bounded because the Worker buffers the whole body in memory
// and the speech-to-text provider rejects files above 25 MB.
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;

const SIZE_LIMITS = {
  image: 25 * 1024 * 1024,
  video: 25 * 1024 * 1024,
  voice: MAX_AUDIO_BYTES,
  audio: MAX_AUDIO_BYTES,
  document: 10 * 1024 * 1024,
};

const EXPIRY_MS = {
  image: null,
  video: 24 * 60 * 60 * 1000,
  voice: 72 * 60 * 60 * 1000,
  // Call recordings are transcribed into Firestore, so their audio expires a
  // day after the call even if the app never gets a chance to delete it.
  audio: 24 * 60 * 60 * 1000,
  document: 72 * 60 * 60 * 1000,
};

const ALLOWED_TYPES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
  "video/mp4",
  "video/webm",
  "audio/mpeg",
  "audio/mp4",
  "audio/wav",
  "audio/ogg",
  "audio/webm",
  "audio/aac",
  "audio/3gpp",
  "application/pdf",
  "text/plain",
  "application/rtf",
  "application/msword",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.ms-excel",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-powerpoint",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
]);

let cachedKeys = null;
let keysExpireAt = 0;

function responseJson(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...headers,
    },
  });
}

function corsHeaders(request) {
  const origin = request.headers.get("Origin");
  const headers = {
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    "Access-Control-Allow-Headers":
      "Authorization, Content-Type, X-File-Name, X-Media-Purpose, X-Media-Category, X-Chat-Id, X-Group-Id, X-Character-Id",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };

  if (origin) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

function base64UrlToBytes(value) {
  const base64 = value
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(base64);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}

function decodeJwtPart(value) {
  return JSON.parse(
    new TextDecoder().decode(base64UrlToBytes(value))
  );
}

async function getFirebaseKeys() {
  if (cachedKeys && Date.now() < keysExpireAt) return cachedKeys;

  const response = await fetch(
    "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"
  );

  if (!response.ok) throw new Error("Unable to retrieve Firebase signing keys");

  const data = await response.json();
  cachedKeys = data.keys;

  const cacheControl = response.headers.get("Cache-Control") || "";
  const match = cacheControl.match(/max-age=(\d+)/i);
  keysExpireAt = Date.now() + (match ? Number(match[1]) : 3600) * 1000;

  return cachedKeys;
}

async function verifyFirebaseToken(request) {
  const authorization = request.headers.get("Authorization") || "";
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  const url = new URL(request.url);

  // Browsers' native audio/video elements cannot reliably attach custom
  // Authorization headers. Accept a Firebase ID token in the query string
  // ONLY for GET requests to /media/*; all other routes still require headers.
  const isMediaGet =
    request.method === "GET" && url.pathname.startsWith("/media/");
  const token = match?.[1] ||
    (isMediaGet ? url.searchParams.get("authToken") : null);

  if (!token) return null;

  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;

    const header = decodeJwtPart(parts[0]);
    const claims = decodeJwtPart(parts[1]);
    const now = Math.floor(Date.now() / 1000);

    if (
      header.alg !== "RS256" ||
      !header.kid ||
      claims.aud !== FIREBASE_PROJECT_ID ||
      claims.iss !==
        `https://securetoken.google.com/${FIREBASE_PROJECT_ID}` ||
      typeof claims.sub !== "string" ||
      claims.sub.length === 0 ||
      claims.sub.length > 128 ||
      typeof claims.exp !== "number" ||
      claims.exp <= now ||
      typeof claims.iat !== "number" ||
      claims.iat > now + 60 ||
      typeof claims.auth_time !== "number" ||
      claims.auth_time > now + 60
    ) {
      return null;
    }

    const keys = await getFirebaseKeys();
    const jwk = keys.find((key) => key.kid === header.kid);
    if (!jwk || jwk.kty !== "RSA") return null;

    const publicKey = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );

    const valid = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      base64UrlToBytes(parts[2]),
      new TextEncoder().encode(`${parts[0]}.${parts[1]}`)
    );

    return valid ? claims : null;
  } catch {
    console.error("Firebase token verification failed");
    return null;
  }
}

async function getFirestoreDocument(collection, documentId, token) {
  if (
    !["chats", "groups"].includes(collection) ||
    !documentId ||
    documentId.length > 150 ||
    documentId.includes("/")
  ) {
    return null;
  }

  const documentUrl =
    `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}` +
    `/databases/(default)/documents/${collection}/${encodeURIComponent(documentId)}`;

  const response = await fetch(documentUrl, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!response.ok) return null;
  return response.json();
}

function firestoreArrayContains(document, field, uid) {
  const values = document?.fields?.[field]?.arrayValue?.values || [];
  return values.some((item) => item.stringValue === uid);
}

async function isChatParticipant(chatId, uid, token) {
  const doc = await getFirestoreDocument("chats", chatId, token);
  return doc !== null && firestoreArrayContains(doc, "participants", uid);
}

async function isGroupMember(groupId, uid, token) {
  const doc = await getFirestoreDocument("groups", groupId, token);
  return doc !== null && firestoreArrayContains(doc, "members", uid);
}

function categoryForContentType(contentType) {
  if (contentType.startsWith("image/")) return "image";
  if (contentType.startsWith("video/")) return "video";
  if (contentType.startsWith("audio/")) return "audio";

  if (
    contentType === "application/pdf" ||
    contentType === "text/plain" ||
    contentType === "application/rtf" ||
    contentType === "application/msword" ||
    contentType.startsWith("application/vnd.openxmlformats-officedocument.") ||
    contentType === "application/vnd.ms-excel" ||
    contentType === "application/vnd.ms-powerpoint"
  ) {
    return "document";
  }

  return null;
}

function getExtension(fileName, contentType) {
  const match = fileName.match(/\.([a-zA-Z0-9]{1,10})$/);
  const extension = match ? match[1].toLowerCase() : "";

  const allowed = new Set([
    "jpg", "jpeg", "png", "webp", "gif", "mp4", "webm",
    "mp3", "m4a", "wav", "ogg", "aac", "3gp", "pdf",
    "txt", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
  ]);

  if (extension && allowed.has(extension)) return extension;

  const defaults = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "image/gif": "gif",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
    "audio/wav": "wav",
    "audio/ogg": "ogg",
    "audio/webm": "webm",
    "audio/aac": "aac",
    "audio/3gpp": "3gp",
    "application/pdf": "pdf",
    "text/plain": "txt",
  };

  return defaults[contentType] || "bin";
}

function safeKeyFromPath(pathname) {
  const prefix = "/media/";
  if (!pathname.startsWith(prefix)) return null;

  const key = pathname.slice(prefix.length);
  const parts = key.split("/");

  if (
    !key ||
    key.length > 300 ||
    key.startsWith("/") ||
    key.includes("\\") ||
    parts.some((part) => !part || part === "." || part === "..")
  ) {
    return null;
  }

  return key;
}

function mediaHasExpired(metadata) {
  const expiry = Number(metadata?.expiresAtMs);
  return Number.isFinite(expiry) && expiry > 0 && Date.now() >= expiry;
}

/**
 * Hex HMAC-SHA256. Used to sign short-lived media links so an image provider
 * (which cannot present a Firebase token) can fetch a picture we keep private.
 */
async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message)
  );
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/** A media link that needs no Firebase token, valid for [ttlMs] only. */
async function signedMediaUrl(env, origin, key, ttlMs = 15 * 60 * 1000) {
  const secret = envString(env.MEDIA_SIGNING_KEY);
  if (!secret) return "";

  const exp = Date.now() + ttlMs;
  const sig = await hmacHex(secret, `${key}|${exp}`);
  return `${origin}/media/${key}?exp=${exp}&sig=${sig}`;
}

/**
 * Serves a media object for a request carrying a valid `exp`/`sig` pair.
 * These requests come from image providers, so they have no Firebase token
 * and are handled before the authentication gate.
 */
async function serveSignedMedia(request, env, url, cors) {
  const key = safeKeyFromPath(url.pathname);
  const secret = envString(env.MEDIA_SIGNING_KEY);
  const sig = (url.searchParams.get("sig") || "").toLowerCase();
  const exp = Number(url.searchParams.get("exp") || 0);

  if (!key || !secret || !sig || !Number.isFinite(exp) || exp <= 0) {
    return responseJson({ error: "This media link is not valid." }, 403, cors);
  }

  if (exp <= Date.now()) {
    return responseJson(
      { error: "This media link has expired.", expired: true },
      410,
      cors
    );
  }

  const expected = await hmacHex(secret, `${key}|${exp}`);
  if (expected !== sig) {
    return responseJson({ error: "This media link is not valid." }, 403, cors);
  }

  const object = await env.MEDIA_BUCKET.get(key);
  if (!object) {
    return responseJson({ error: "Media not found" }, 404, cors);
  }

  if (mediaHasExpired(object.customMetadata || {})) {
    return responseJson(
      { error: "Media expired.", expired: true },
      410,
      cors
    );
  }

  const headers = new Headers(cors);
  object.writeHttpMetadata(headers);
  headers.set("ETag", object.httpEtag);
  headers.set("Cache-Control", "private, no-store");
  headers.set("X-Content-Type-Options", "nosniff");

  return new Response(object.body, { status: 200, headers });
}

/** Base64 for a byte array, chunked so large pictures cannot blow the stack. */
function bytesToBase64(bytes) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let index = 0; index < bytes.length; index += chunkSize) {
    binary += String.fromCharCode.apply(
      null,
      bytes.subarray(index, index + chunkSize)
    );
  }
  return btoa(binary);
}

// =====================================================================
// AI ROUTES (Groq)
//
// The three AI endpoints below reuse the existing Firebase ID token
// verification and the existing chat/group membership checks. They never
// touch MEDIA_BUCKET, never write to Firestore, and never expose the Groq
// API key: it is read from the GROQ_API_KEY Worker secret only.
//
// Meeting minutes are returned as JSON and saved by the Flutter client
// through MeetingMinutesService, so the existing data model and the
// existing Firestore write path are untouched.
// =====================================================================

const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const GROQ_MODEL = "openai/gpt-oss-120b";

// Reported by /health so a deployment can be identified without guessing.
// Bump this when a change needs to be confirmed live.
const WORKER_BUILD = "2026-11-16-characters";
const WORKER_FEATURES = [
  "characters",
  "character-photos",
  "signed-media",
];
// Groq's image-capable model, used when a character is built from a photo.
const GROQ_VISION_MODEL = "meta-llama/llama-4-scout-17b-16e-instruct";
// A reference picture is inlined for the vision call, so it must stay small.
const MAX_REFERENCE_BYTES = 8 * 1024 * 1024;

const MAX_INPUT_CHARS = 16000;
const MAX_SUMMARY_MESSAGES = 30;
const MAX_REPLY_MESSAGES = 10;
const MAX_MESSAGE_CHARS = 4000;
const MAX_REPLY_INPUT_CHARS = 2000;
const MAX_AI_BODY_BYTES = 64 * 1024;

const GROQ_MAX_ATTEMPTS = 2;
const GROQ_RETRYABLE_STATUS = new Set([408, 409, 429, 500, 502, 503, 504]);
const GROQ_MAX_RETRY_AFTER_MS = 10000;
const GROQ_MAX_BACKOFF_MS = 4000;

// Local-development fallback only. It is NOT a global quota: a Worker runs
// on many isolates, so production should configure an authoritative limiter.
// If a configured Cloudflare binding fails, AI requests fail closed with 503.
const AI_ISOLATE_WINDOW_MS = 60 * 1000;
const AI_ISOLATE_LIMIT = 10;
const aiIsolateHits = new Map();

const AI_TIMEOUTS = {
  minutes: 30000,
  summary: 20000,
  replies: 12000,
  transcribe: 90000,
  transcriptSection: 25000,
};

// Speech-to-text. Groq accepts flac/mp3/mp4/mpeg/mpga/m4a/ogg/wav/webm and a
// single audio track, so call recordings are captured as audio-only MP4 and
// uploaded as m4a. Raw ADTS AAC is NOT an accepted input format.
const GROQ_STT_URL = "https://api.groq.com/openai/v1/audio/transcriptions";
const GROQ_STT_MODEL = "whisper-large-v3";
const MAX_STT_BYTES = 25 * 1024 * 1024;

// A recorded call transcript is much longer than the minutes prompt budget, so
// it is condensed section by section before the minutes prompt sees it.
const MAX_CALL_TRANSCRIPT_CHARS = 120000;
const TRANSCRIPT_SECTION_CHARS = 14000;
const MAX_TRANSCRIPT_SECTIONS = 10;
const TRANSCRIPT_SECTION_CONCURRENCY = 3;
const STT_RETRYABLE_STATUS = new Set([408, 409, 429, 500, 502, 503, 504]);

class AiError extends Error {
  constructor(code, message, status, retryAfterSeconds = null) {
    super(message);
    this.name = "AiError";
    this.code = code;
    this.status = status;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

const MINUTES_SYSTEM_PROMPT = [
  "You convert raw conversation or call notes into structured meeting minutes.",
  "Return exactly one JSON object that matches the provided schema: no prose, no markdown, no code fences.",
  "Rules:",
  "- title: a short, specific title for the conversation",
  "- summary: 3 to 6 plain sentences covering purpose, main points and outcome",
  "- keyDecisions: at most 8 concrete decisions; exclude small talk and opinions",
  "- actionItems: one entry per concrete follow-up; use null for assignee and dueDate unless the notes state them",
  "- transcript: reconstruct the exchange from the notes in their original order; use a relative marker such as 00:00 for timestamp when the notes do not give one",
  "- never invent names, dates, numbers, decisions or attendees",
  "- keep the language of the notes",
].join("\n");

const SUMMARY_SYSTEM_PROMPT = [
  "You summarize chat conversations for the people who took part in them.",
  "Return plain text only: no markdown, no headings, no JSON, no bullet characters.",
  "Write 3 to 5 short sentences covering what the conversation was about, the key points or decisions, and anything still open.",
  "Name speakers only when it makes the summary clearer.",
  "Never invent details that are not in the messages, and keep the language of the conversation.",
].join("\n");

const REPLIES_SYSTEM_PROMPT = [
  "You suggest short chat replies the user could send next, based on the recent messages.",
  "Return exactly one JSON object that matches the provided schema: no prose, no markdown, no code fences.",
  "Rules:",
  "- exactly 3 replies, each under 120 characters",
  "- make them genuinely different in intent, for example agree, ask a follow-up, offer a next step",
  "- sound like a real person in a chat app: no numbering, no quotes, no emojis unless the conversation uses them",
  "- never commit the user to a time, price or promise that the messages do not support",
  "- write in the language of the conversation",
].join("\n");

const MINUTES_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    summary: { type: "string" },
    keyDecisions: {
      type: "array",
      items: { type: "string" },
    },
    actionItems: {
      type: "array",
      items: {
        type: "object",
        properties: {
          task: { type: "string" },
          assignee: { type: ["string", "null"] },
          dueDate: { type: ["string", "null"] },
        },
        required: ["task", "assignee", "dueDate"],
        additionalProperties: false,
      },
    },
    transcript: {
      type: "array",
      items: {
        type: "object",
        properties: {
          speaker: { type: "string" },
          text: { type: "string" },
          timestamp: { type: "string" },
        },
        required: ["speaker", "text", "timestamp"],
        additionalProperties: false,
      },
    },
  },
  required: ["title", "summary", "keyDecisions", "actionItems", "transcript"],
  additionalProperties: false,
};

const REPLIES_SCHEMA = {
  type: "object",
  properties: {
    replies: {
      type: "array",
      items: { type: "string" },
    },
  },
  required: ["replies"],
  additionalProperties: false,
};

function clampText(value, maxLength) {
  if (typeof value !== "string") return "";
  return value.trim().slice(0, maxLength);
}

function buildMinutesUserPrompt({
  conversationTitle,
  conversationType,
  participantNames,
  durationSeconds,
  rawContent,
}) {
  const names = Object.values(participantNames || {})
    .map((name) => clampText(name, 80))
    .filter(Boolean)
    .slice(0, 30);

  return [
    `Conversation: ${conversationTitle}`,
    `Type: ${conversationType}`,
    names.length > 0 ? `Known participants: ${names.join(", ")}` : "",
    durationSeconds > 0 ? `Approximate duration: ${Math.round(durationSeconds / 60)} minutes` : "",
    "",
    "Raw notes:",
    rawContent,
  ]
    .filter((line) => line !== "")
    .join("\n");
}

function buildSummaryUserPrompt({
  conversationTitle,
  conversationType,
  transcript,
}) {
  return [
    `Conversation: ${conversationTitle}`,
    `Type: ${conversationType}`,
    "",
    "Messages, oldest first:",
    transcript,
  ].join("\n");
}

function buildRepliesUserPrompt({ transcript }) {
  return ["Recent messages, oldest first:", transcript].join("\n");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function retryDelayMs(response, attempt) {
  const retryAfter = response.headers.get("retry-after");
  if (retryAfter) {
    const seconds = Number(retryAfter);
    if (Number.isFinite(seconds) && seconds > 0) {
      return Math.min(seconds * 1000, GROQ_MAX_RETRY_AFTER_MS);
    }
  }
  const backoff = 500 * 2 ** (attempt - 1);
  return Math.min(backoff + Math.floor(Math.random() * 250), GROQ_MAX_BACKOFF_MS);
}

function logGroqRateLimits(response, status) {
  if (status !== 429) return;
  const remainingRequests = response.headers.get("x-ratelimit-remaining-requests");
  const remainingTokens = response.headers.get("x-ratelimit-remaining-tokens");
  const retryAfter = response.headers.get("retry-after");
  console.log(
    `Groq rate limited. remaining-requests=${remainingRequests ?? "?"} ` +
      `remaining-tokens=${remainingTokens ?? "?"} retry-after=${retryAfter ?? "?"}`
  );
}

function mapGroqStatus(status, retryAfterSeconds) {
  if (status === 429) {
    return new AiError(
      "RATE_LIMITED",
      "The AI service rate limit was reached. Please wait a moment and try again.",
      429,
      retryAfterSeconds
    );
  }
  if (status === 413) {
    return new AiError(
      "INVALID_REQUEST",
      "The conversation is too long for the AI service. Please shorten it and try again.",
      400
    );
  }
  if (status === 401 || status === 403) {
    return new AiError(
      "AI_SERVICE_UNAVAILABLE",
      "The AI service is temporarily unavailable. Please try again in a few moments.",
      503
    );
  }
  if (status === 404) {
    return new AiError(
      "AI_SERVICE_UNAVAILABLE",
      "The AI model is unavailable right now. Please try again later.",
      503
    );
  }
  if (status === 400 || status === 422) {
    return new AiError(
      "BAD_AI_RESPONSE",
      "The AI request was rejected. Please check the content and try again.",
      502
    );
  }
  return new AiError(
    "AI_SERVICE_UNAVAILABLE",
    "The AI service is temporarily unavailable. Please try again in a few moments.",
    503
  );
}

function wantsSchemaFallback(status, detail) {
  if (status !== 400 && status !== 422) return false;
  const text = (detail || "").toLowerCase();
  return text.includes("json") || text.includes("schema") || text.includes("response_format");
}

/**
 * Calls Groq's OpenAI-compatible endpoint with a bounded timeout and at most
 * one retry. Returns the assistant message content as a string.
 *
 * The API key is read from env.GROQ_API_KEY, sent only in the request header,
 * and never logged or returned to the client.
 */
async function requestGroqCompletion(env, options) {
  const apiKey = typeof env?.GROQ_API_KEY === "string" ? env.GROQ_API_KEY.trim() : "";
  if (!apiKey) {
    throw new AiError(
      "AI_NOT_CONFIGURED",
      "AI is not configured on the server yet. Please contact the project owner.",
      503
    );
  }

  const baseBody = {
    model: options.model || envString(env?.GROQ_MODEL) || GROQ_MODEL,
    messages: [
      { role: "system", content: options.systemPrompt },
      // A picture travels as an OpenAI-style content part; the text-only path
      // keeps sending a plain string so nothing else changes behaviour.
      options.imageDataUri
        ? {
            role: "user",
            content: [
              { type: "text", text: options.userPrompt },
              {
                type: "image_url",
                image_url: { url: options.imageDataUri },
              },
            ],
          }
        : { role: "user", content: options.userPrompt },
    ],
    temperature: options.temperature,
    max_completion_tokens: options.maxCompletionTokens,
  };

  let useFallbackFormat = false;

  for (let attempt = 1; attempt <= GROQ_MAX_ATTEMPTS; attempt += 1) {
    const body = /** @type {Record<string, any>} */ ({ ...baseBody });
    if (options.schema) {
      body.response_format = useFallbackFormat
        ? { type: "json_object" }
        : {
            type: "json_schema",
            json_schema: {
              name: options.schemaName,
              strict: true,
              schema: options.schema,
            },
          };
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs);
    let response;

    try {
      response = await fetch(GROQ_API_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (error) {
      if (error?.name === "AbortError") {
        throw new AiError(
          "AI_TIMEOUT",
          "The AI request took too long. Please try again.",
          504
        );
      }
      console.error(`Groq request failed (attempt ${attempt}).`);
      if (attempt >= GROQ_MAX_ATTEMPTS) {
        throw new AiError(
          "AI_SERVICE_UNAVAILABLE",
          "The AI service is temporarily unavailable. Please try again in a few moments.",
          503
        );
      }
      await sleep(retryDelayMs({ headers: new Headers() }, attempt));
      continue;
    } finally {
      clearTimeout(timer);
    }

    if (!response.ok) {
      const detail = (await response.text().catch(() => "")).slice(0, 300);
      logGroqRateLimits(response, response.status);
      console.error(`Groq responded ${response.status} (attempt ${attempt}).`);

      if (
        options.schema &&
        !useFallbackFormat &&
        wantsSchemaFallback(response.status, detail)
      ) {
        // Some Groq model/schema combinations reject strict json_schema.
        // Fall back once to json_object before surfacing an error.
        console.error("Groq rejected the JSON schema; retrying with json_object.");
        useFallbackFormat = true;
        continue;
      }

      if (
        GROQ_RETRYABLE_STATUS.has(response.status) &&
        attempt < GROQ_MAX_ATTEMPTS
      ) {
        const retryAfter = Number(response.headers.get("retry-after"));
        await sleep(retryDelayMs(response, attempt));
        continue;
      }

      const retryAfter = Number(response.headers.get("retry-after"));
      throw mapGroqStatus(
        response.status,
        Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : null
      );
    }

    let data;
    try {
      data = await response.json();
    } catch {
      console.error("Groq returned a body that was not JSON.");
      throw new AiError(
        "BAD_AI_RESPONSE",
        "The AI service returned an unreadable response. Please try again.",
        502
      );
    }

    const choice = data?.choices?.[0];
    if (choice?.finish_reason === "length") {
      throw new AiError(
        "BAD_AI_RESPONSE",
        "The AI response was cut off before it finished. Please try a shorter conversation.",
        502
      );
    }

    const content = choice?.message?.content;
    if (typeof content !== "string" || content.trim() === "") {
      console.error("Groq returned an empty completion.");
      throw new AiError(
        "BAD_AI_RESPONSE",
        "The AI service returned an empty response. Please try again.",
        502
      );
    }

    return content.trim();
  }

  console.error("Groq request exhausted its attempts.");
  throw new AiError(
    "AI_SERVICE_UNAVAILABLE",
    "The AI service is temporarily unavailable. Please try again in a few moments.",
    503
  );
}

function parseJsonContent(content) {
  const cleaned = content
    .replace(/^\s*```(?:json)?/i, "")
    .replace(/```\s*$/i, "")
    .trim();

  let parsed;
  try {
    parsed = JSON.parse(cleaned);
  } catch {
    throw new AiError(
      "BAD_AI_RESPONSE",
      "The AI response could not be understood. Please try again.",
      502
    );
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new AiError(
      "BAD_AI_RESPONSE",
      "The AI response could not be understood. Please try again.",
      502
    );
  }

  return parsed;
}

function toStringArray(value, { maxItems, maxChars }) {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item) => typeof item === "string")
    .map((item) => item.trim().slice(0, maxChars))
    .filter(Boolean)
    .slice(0, maxItems);
}

function normalizeMinute(json) {
  const summary = clampText(json.summary, 4000);
  if (!summary) {
    throw new AiError(
      "BAD_AI_RESPONSE",
      "The AI response did not include a summary. Please try again.",
      502
    );
  }

  const actionItems = Array.isArray(json.actionItems)
    ? json.actionItems
        .filter((item) => item && typeof item === "object")
        .map((item) => ({
          task: clampText(item.task, 300),
          assignee: clampText(item.assignee, 120) || null,
          dueDate: clampText(item.dueDate, 60) || null,
        }))
        .filter((item) => item.task)
        .slice(0, 20)
    : [];

  const transcript = Array.isArray(json.transcript)
    ? json.transcript
        .filter((segment) => segment && typeof segment === "object")
        .map((segment) => ({
          speaker: clampText(segment.speaker, 120) || "Participant",
          text: clampText(segment.text, 2000),
          timestamp: clampText(segment.timestamp, 20) || "00:00",
        }))
        .filter((segment) => segment.text)
        .slice(0, 200)
    : [];

  return {
    title: clampText(json.title, 200),
    summary,
    keyDecisions: toStringArray(json.keyDecisions, { maxItems: 12, maxChars: 300 }),
    actionItems,
    transcript,
  };
}

function normalizeReplies(json) {
  return toStringArray(json.replies, { maxItems: 5, maxChars: 200 }).slice(0, 3);
}

/**
 * Coarse per-user guard. Uses env.AI_RATE_LIMITER when the binding exists,
 * otherwise falls back to an in-isolate counter. Returning false means the
 * caller is throttled.
 */
async function allowAiRequest(env, uid) {
  // If a Cloudflare rate-limit binding is configured, it is authoritative.
  // Never silently fall back to a weaker per-isolate counter when it fails.
  if (env?.AI_RATE_LIMITER !== undefined && env?.AI_RATE_LIMITER !== null) {
    if (typeof env.AI_RATE_LIMITER.limit !== "function") {
      throw new AiError(
        "AI_RATE_LIMITER_UNAVAILABLE",
        "The AI rate limiter is temporarily unavailable. Please try again later.",
        503
      );
    }

    try {
      const outcome = await env.AI_RATE_LIMITER.limit({ key: `ai:${uid}` });
      if (!outcome || typeof outcome.success !== "boolean") {
        throw new Error("Malformed rate limiter response");
      }
      return outcome.success;
    } catch {
      console.error("AI rate limiter binding failed.");
      throw new AiError(
        "AI_RATE_LIMITER_UNAVAILABLE",
        "The AI rate limiter is temporarily unavailable. Please try again later.",
        503
      );
    }
  }

  // Local-development fallback only. This counter is per isolate, not global.
  const now = Date.now();
  const entry = aiIsolateHits.get(uid);

  if (!entry || now - entry.windowStart >= AI_ISOLATE_WINDOW_MS) {
    if (aiIsolateHits.size > 500) {
      for (const [key, value] of aiIsolateHits) {
        if (now - value.windowStart >= AI_ISOLATE_WINDOW_MS) {
          aiIsolateHits.delete(key);
        }
      }
    }
    aiIsolateHits.set(uid, { windowStart: now, count: 1 });
    return true;
  }

  entry.count += 1;
  return entry.count <= AI_ISOLATE_LIMIT;
}

async function enforceAiRateLimit(env, uid) {
  if (!(await allowAiRequest(env, uid))) {
    throw new AiError(
      "RATE_LIMITED",
      "You are sending AI requests too quickly. Please wait a minute and try again.",
      429,
      60
    );
  }
}

async function readAiJsonBody(request) {
  const contentType = (request.headers.get("Content-Type") || "")
    .split(";")[0]
    .trim()
    .toLowerCase();

  if (contentType !== "application/json") {
    throw new AiError(
      "INVALID_REQUEST",
      "AI requests must be sent as application/json.",
      400
    );
  }

  const declaredLength = Number(request.headers.get("Content-Length") || "0");
  if (Number.isFinite(declaredLength) && declaredLength > MAX_AI_BODY_BYTES) {
    throw new AiError(
      "INVALID_REQUEST",
      "The request body is too large.",
      413
    );
  }

  let text;
  try {
    text = await request.text();
  } catch {
    throw new AiError(
      "INVALID_REQUEST",
      "The request body could not be read.",
      400
    );
  }

  if (!text || text.length > MAX_AI_BODY_BYTES) {
    throw new AiError(
      "INVALID_REQUEST",
      text ? "The request body is too large." : "The request body is empty.",
      text ? 413 : 400
    );
  }

  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new AiError(
      "INVALID_REQUEST",
      "The request body must be valid JSON.",
      400
    );
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new AiError(
      "INVALID_REQUEST",
      "The request body must be a JSON object.",
      400
    );
  }

  return parsed;
}

function readConversation(body) {
  const conversationId = clampText(body.conversationId, 160);
  const conversationType = clampText(body.conversationType, 20).toLowerCase();

  if (!conversationId || conversationId.length > 150 || conversationId.includes("/")) {
    throw new AiError(
      "INVALID_REQUEST",
      "A valid conversationId is required.",
      400
    );
  }

  if (conversationType !== "private" && conversationType !== "group") {
    throw new AiError(
      "INVALID_REQUEST",
      'conversationType must be "private" or "group".',
      400
    );
  }

  return { conversationId, conversationType };
}

async function authorizeConversation(conversationId, conversationType, user, token) {
  const allowed =
    conversationType === "group"
      ? await isGroupMember(conversationId, user.sub, token)
      : await isChatParticipant(conversationId, user.sub, token);

  if (!allowed) {
    throw new AiError(
      "FORBIDDEN",
      conversationType === "group"
        ? "You are not a member of this group."
        : "You are not a participant in this chat.",
      403
    );
  }
}

function readMessageList(value, { label, maxItems, maxChars }) {
  if (!Array.isArray(value)) {
    throw new AiError(
      "INVALID_REQUEST",
      `"${label}" must be an array of strings.`,
      400
    );
  }

  const items = value
    .filter((item) => typeof item === "string")
    .map((item) => item.trim().slice(0, maxChars))
    .filter(Boolean);

  if (items.length > maxItems) {
    throw new AiError(
      "INVALID_REQUEST",
      `"${label}" may contain at most ${maxItems} entries.`,
      400
    );
  }

  return items;
}

/** Keeps the most recent lines and drops the oldest until the budget fits. */
function fitLines(lines, maxChars) {
  let text = lines.join("\n");
  while (text.length > maxChars && lines.length > 1) {
    lines = lines.slice(1);
    text = lines.join("\n");
  }
  return text.slice(0, maxChars);
}

function readParticipantNames(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const names = {};
  for (const [uid, name] of Object.entries(value).slice(0, 50)) {
    if (typeof uid !== "string" || uid.length === 0 || uid.length > 128) continue;
    const cleaned = clampText(name, 80);
    if (cleaned) names[uid] = cleaned;
  }
  return names;
}

function readDurationSeconds(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds)) return 0;
  return Math.max(0, Math.min(Math.round(seconds), 24 * 60 * 60));
}

async function handleSummarizeChat(request, env, user, token, cors) {
  const body = await readAiJsonBody(request);
  const { conversationId, conversationType } = readConversation(body);

  const conversationTitle = clampText(body.conversationTitle, 200) || "this conversation";
  const messages = readMessageList(body.messages, {
    label: "messages",
    maxItems: MAX_SUMMARY_MESSAGES,
    maxChars: MAX_MESSAGE_CHARS,
  });

  if (messages.length === 0) {
    throw new AiError(
      "INVALID_REQUEST",
      "At least one message is required to generate a summary.",
      400
    );
  }

  await authorizeConversation(conversationId, conversationType, user, token);
  await enforceAiRateLimit(env, user.sub);

  const content = await requestGroqCompletion(env, {
    systemPrompt: SUMMARY_SYSTEM_PROMPT,
    userPrompt: buildSummaryUserPrompt({
      conversationTitle,
      conversationType,
      transcript: fitLines(messages, MAX_INPUT_CHARS),
    }),
    schema: null,
    schemaName: null,
    temperature: 0.4,
    maxCompletionTokens: 800,
    timeoutMs: AI_TIMEOUTS.summary,
  });

  const summary = clampText(content, 6000);
  if (!summary) {
    throw new AiError(
      "BAD_AI_RESPONSE",
      "The AI returned an empty summary. Please try again.",
      502
    );
  }

  return responseJson(
    { provider: "groq", model: GROQ_MODEL, summary },
    200,
    cors
  );
}

async function handleGenerateMinutes(request, env, user, token, cors) {
  const body = await readAiJsonBody(request);
  const { conversationId, conversationType } = readConversation(body);

  const manualNotes =
    typeof body.rawContent === "string" ? body.rawContent.trim() : "";

  // A saved call transcript can be far longer than one prompt, so it is
  // condensed section by section instead of being rejected or truncated.
  const callTranscript =
    typeof body.transcript === "string" ? body.transcript.trim() : "";

  if (!manualNotes && !callTranscript) {
    throw new AiError(
      "INVALID_REQUEST",
      "Conversation notes are required to generate minutes.",
      400
    );
  }
  if (manualNotes.length > MAX_INPUT_CHARS) {
    throw new AiError(
      "INVALID_REQUEST",
      `The notes are too long (${manualNotes.length} of ${MAX_INPUT_CHARS} characters allowed).`,
      400
    );
  }
  if (callTranscript.length > MAX_CALL_TRANSCRIPT_CHARS) {
    throw new AiError(
      "INVALID_REQUEST",
      `This transcript is too long (${callTranscript.length} of ${MAX_CALL_TRANSCRIPT_CHARS} characters allowed).`,
      413
    );
  }

  const conversationTitle = clampText(body.conversationTitle, 200) || "this conversation";
  const participantNames = readParticipantNames(body.participantNames);
  const durationSeconds = readDurationSeconds(body.durationSeconds);

  await authorizeConversation(conversationId, conversationType, user, token);
  await enforceAiRateLimit(env, user.sub);

  // Manual notes keep their existing behaviour; a transcript replaces them.
  let rawContent = manualNotes;
  let condensedFromTranscript = false;

  if (!rawContent && callTranscript) {
    rawContent = callTranscript;
    if (callTranscript.length > MAX_INPUT_CHARS) {
      rawContent = (await condenseTranscript(env, callTranscript)).slice(
        0,
        MAX_INPUT_CHARS
      );
      condensedFromTranscript = true;
    }
  }

  const content = await requestGroqCompletion(env, {
    systemPrompt: MINUTES_SYSTEM_PROMPT,
    userPrompt: buildMinutesUserPrompt({
      conversationTitle,
      conversationType,
      participantNames,
      durationSeconds,
      rawContent,
    }),
    schema: MINUTES_SCHEMA,
    schemaName: "meeting_minutes",
    temperature: 0.2,
    maxCompletionTokens: 3000,
    timeoutMs: AI_TIMEOUTS.minutes,
  });

  const minute = normalizeMinute(parseJsonContent(content));

  return responseJson(
    { provider: "groq", model: GROQ_MODEL, minute },
    200,
    cors
  );
}

async function handleSmartReplies(request, env, user, token, cors) {
  const body = await readAiJsonBody(request);
  const { conversationId, conversationType } = readConversation(body);

  const recentMessages = readMessageList(body.recentMessages, {
    label: "recentMessages",
    maxItems: MAX_REPLY_MESSAGES,
    maxChars: MAX_REPLY_INPUT_CHARS,
  });

  await authorizeConversation(conversationId, conversationType, user, token);

  if (recentMessages.length === 0) {
    return responseJson(
      { provider: "groq", model: GROQ_MODEL, replies: [] },
      200,
      cors
    );
  }

  await enforceAiRateLimit(env, user.sub);

  const content = await requestGroqCompletion(env, {
    systemPrompt: REPLIES_SYSTEM_PROMPT,
    userPrompt: buildRepliesUserPrompt({
      transcript: fitLines(recentMessages, MAX_INPUT_CHARS),
    }),
    schema: REPLIES_SCHEMA,
    schemaName: "smart_replies",
    temperature: 0.7,
    maxCompletionTokens: 300,
    timeoutMs: AI_TIMEOUTS.replies,
  });

  const replies = normalizeReplies(parseJsonContent(content));

  return responseJson(
    { provider: "groq", model: GROQ_MODEL, replies },
    200,
    cors
  );
}

function readGroqApiKey(env) {
  const apiKey =
    typeof env?.GROQ_API_KEY === "string" ? env.GROQ_API_KEY.trim() : "";
  if (!apiKey) {
    throw new AiError(
      "AI_NOT_CONFIGURED",
      "AI is not configured on the server yet. Please contact the project owner.",
      503
    );
  }
  return apiKey;
}

/**
 * Shapes a Groq verbose_json transcription into the small payload the app
 * stores. Text is never logged here.
 */
function normalizeTranscription(payload) {
  const text = clampText(payload?.text, 200000);

  const segments = Array.isArray(payload?.segments)
    ? payload.segments
        .filter((segment) => segment && typeof segment === "object")
        .map((segment) => {
          const start = Number(segment.start);
          const end = Number(segment.end);
          return {
            start: Number.isFinite(start) ? Math.max(0, start) : 0,
            end: Number.isFinite(end) ? Math.max(0, end) : 0,
            text: clampText(segment.text, 4000),
          };
        })
        .filter((segment) => segment.text)
        .slice(0, 5000)
    : [];

  const reportedDuration = Number(payload?.duration);
  const durationSeconds = Number.isFinite(reportedDuration) && reportedDuration > 0
    ? reportedDuration
    : segments.length > 0
      ? segments[segments.length - 1].end
      : 0;

  return {
    text,
    segments,
    durationSeconds: Math.round(durationSeconds * 100) / 100,
    language: clampText(payload?.language, 20) || null,
  };
}

/**
 * Sends one audio chunk to Groq's speech-to-text endpoint with a bounded
 * timeout and at most one retry. The provider key stays server-side.
 */
async function requestGroqTranscription(
  env,
  { bytes, contentType, fileName, language }
) {
  const apiKey = readGroqApiKey(env);

  for (let attempt = 1; attempt <= GROQ_MAX_ATTEMPTS; attempt += 1) {
    const form = new FormData();
    form.append("file", new Blob([bytes], { type: contentType }), fileName);
    form.append("model", GROQ_STT_MODEL);
    form.append("response_format", "verbose_json");
    form.append("timestamp_granularities[]", "segment");
    if (language) form.append("language", language);

    const controller = new AbortController();
    const timer = setTimeout(
      () => controller.abort(),
      AI_TIMEOUTS.transcribe
    );
    let response;

    try {
      response = await fetch(GROQ_STT_URL, {
        method: "POST",
        headers: { Authorization: `Bearer ${apiKey}` },
        body: form,
        signal: controller.signal,
      });
    } catch (error) {
      if (error?.name === "AbortError") {
        throw new AiError(
          "AI_TIMEOUT",
          "The transcription took too long. Please try again.",
          504
        );
      }
      console.error(`Groq transcription request failed (attempt ${attempt}).`);
      if (attempt >= GROQ_MAX_ATTEMPTS) {
        throw new AiError(
          "AI_SERVICE_UNAVAILABLE",
          "The transcription service is temporarily unavailable. Please try again.",
          503
        );
      }
      await sleep(retryDelayMs({ headers: new Headers() }, attempt));
      continue;
    } finally {
      clearTimeout(timer);
    }

    if (!response.ok) {
      logGroqRateLimits(response, response.status);
      console.error(
        `Groq transcription responded ${response.status} (attempt ${attempt}).`
      );

      if (
        STT_RETRYABLE_STATUS.has(response.status) &&
        attempt < GROQ_MAX_ATTEMPTS
      ) {
        await sleep(retryDelayMs(response, attempt));
        continue;
      }

      // Transcription-specific copy: the generic mapper talks about
      // conversations being too long, which is misleading for audio.
      if (response.status === 413) {
        throw new AiError(
          "INVALID_REQUEST",
          "This recording part is too large for the transcription service.",
          413
        );
      }
      if (response.status === 400 || response.status === 422) {
        throw new AiError(
          "INVALID_REQUEST",
          "The transcription service rejected this audio file.",
          502
        );
      }

      const retryAfter = Number(response.headers.get("retry-after"));
      throw mapGroqStatus(
        response.status,
        Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : null
      );
    }

    let data;
    try {
      data = await response.json();
    } catch {
      console.error("Groq transcription returned a body that was not JSON.");
      throw new AiError(
        "BAD_AI_RESPONSE",
        "The transcription service returned an unreadable response. Please try again.",
        502
      );
    }

    const transcription = normalizeTranscription(data);
    if (!transcription.text && transcription.segments.length === 0) {
      throw new AiError(
        "BAD_AI_RESPONSE",
        "No speech could be recognised in this recording.",
        502
      );
    }

    return transcription;
  }

  throw new AiError(
    "AI_SERVICE_UNAVAILABLE",
    "The transcription service is temporarily unavailable. Please try again.",
    503
  );
}

/**
 * Transcribes one uploaded recording chunk.
 *
 * The audio stays in R2 after this call: the client deletes it only once every
 * chunk is transcribed and the assembled transcript is saved in Firestore.
 * A repeated request for the same chunk is harmless; it returns the same text
 * and the client stores it against a stable chunk id, so no duplicate
 * transcript entries are produced.
 */
// -------------------- AI UNIVERSE: CHARACTERS --------------------

const CHARACTER_CATEGORIES = [
  "human",
  "animal",
  "mythical",
  "legendary",
  "object",
  "fantasy",
];

const CHARACTER_ROLES = [
  "companion",
  "friend",
  "tutor",
  "musician",
  "storyteller",
  "custom",
];

const CHARACTER_SCHEMA = {
  type: "object",
  properties: {
    name: { type: "string" },
    category: { type: "string", enum: CHARACTER_CATEGORIES },
    role: { type: "string", enum: CHARACTER_ROLES },
    appearance: { type: "string" },
    personality: { type: "string" },
    backstory: { type: "string" },
    interests: { type: "array", items: { type: "string" } },
    speakingStyle: { type: "string" },
    language: { type: "string" },
    imagePrompt: { type: "string" },
  },
  required: [
    "name",
    "category",
    "role",
    "appearance",
    "personality",
    "backstory",
    "interests",
    "speakingStyle",
    "language",
    "imagePrompt",
  ],
  additionalProperties: false,
};

const CHARACTER_SYSTEM_PROMPT = `You design fictional AI characters for the Yoked In app.
Return only JSON matching the provided schema.
Rules:
- Every character is fictional. Never describe a real, identifiable private person.
- The character must be an adult unless the description is clearly a child character used for education or storytelling; never write sexual or romantic content for a minor.
- Write the appearance as a visual description an image model can render: age, face, hair, skin, build, clothing, mood, setting.
- Write the personality and backstory in second person as instructions to the character ("You are ..."), because this text becomes the character's system prompt later.
- speakingStyle describes how the character talks: tone, pace, vocabulary, accent hints, habits.
- imagePrompt is a single photorealistic portrait prompt that stays consistent with the appearance.
- Keep each field concise: appearance and imagePrompt at most 120 words, personality and backstory at most 120 words.`;

function oneOf(value, allowed, fallback) {
  const text = clampText(value, 24).toLowerCase();
  return allowed.includes(text) ? text : fallback;
}

function stringList(value, maxItems, maxChars) {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => clampText(item, maxChars))
    .filter(Boolean)
    .slice(0, maxItems);
}

/**
 * Reads an uploaded picture as a data URI so a vision model can look at it
 * without the bucket ever becoming public.
 */
async function readReferenceDataUri(env, user, imageKey) {
  if (imageKey.includes("\\") || !imageKey.startsWith(`${user.sub}/`)) {
    throw new AiError(
      "FORBIDDEN",
      "You can only use your own pictures as a reference.",
      403
    );
  }

  const object = await env.MEDIA_BUCKET.get(imageKey);
  if (!object) {
    throw new AiError(
      "MEDIA_NOT_FOUND",
      "The uploaded picture could not be found. Please upload it again.",
      404
    );
  }

  const contentType = (object.httpMetadata?.contentType || "")
    .split(";")[0]
    .trim()
    .toLowerCase();

  if (!contentType.startsWith("image/")) {
    throw new AiError(
      "INVALID_REQUEST",
      "Reference pictures must be images.",
      415
    );
  }

  if ((Number(object.size) || 0) > MAX_REFERENCE_BYTES) {
    throw new AiError(
      "INVALID_REQUEST",
      `A reference picture must be smaller than ${Math.floor(
        MAX_REFERENCE_BYTES / 1024 / 1024
      )} MB.`,
      413
    );
  }

  const bytes = new Uint8Array(await object.arrayBuffer());
  return `data:${contentType};base64,${bytesToBase64(bytes)}`;
}

async function handleCharacterDraft(request, env, user, token, cors) {
  const body = await readAiJsonBody(request);
  const description = clampText(body.description, 2000);
  const imageKey = clampText(body.imageKey, 300);

  if (!description && !imageKey) {
    throw new AiError(
      "INVALID_REQUEST",
      "Describe the character in a little more detail first.",
      400
    );
  }

  if (!imageKey && description.length < 10) {
    throw new AiError(
      "INVALID_REQUEST",
      "Describe the character in a little more detail first.",
      400
    );
  }

  await enforceAiRateLimit(env, user.sub);

  const category = oneOf(body.category, CHARACTER_CATEGORIES, "human");
  const role = oneOf(body.role, CHARACTER_ROLES, "companion");
  const imageDataUri = imageKey
    ? await readReferenceDataUri(env, user, imageKey)
    : "";

  const content = await requestGroqCompletion(env, {
    systemPrompt: imageDataUri
      ? `${CHARACTER_SYSTEM_PROMPT}\n- The picture shows the person the character should be. Describe what you actually see (age, face, hair, skin, build, clothing, mood) and keep the character consistent with it.`
      : CHARACTER_SYSTEM_PROMPT,
    userPrompt: imageDataUri
      ? "Study the attached picture, then write the character it shows.\n" +
        (description ? `The user adds:\n"""\n${description}\n"""\n` : "") +
        `Preferred category: ${category}\nPreferred role: ${role}\n` +
        "Write the character now."
      : `The user describes the character as:\n"""\n${description}\n"""\n` +
        `Preferred category: ${category}\nPreferred role: ${role}\n` +
        "Write the character now.",
    imageDataUri: imageDataUri || undefined,
    model: imageDataUri
      ? envString(env.GROQ_VISION_MODEL, GROQ_VISION_MODEL)
      : undefined,
    schema: CHARACTER_SCHEMA,
    schemaName: "ai_character",
    temperature: 0.7,
    maxCompletionTokens: 1200,
    timeoutMs: 45000,
  });

  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch {
    throw new AiError(
      "BAD_AI_RESPONSE",
      "The AI response could not be understood. Please try again.",
      502
    );
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new AiError(
      "BAD_AI_RESPONSE",
      "The AI response could not be understood. Please try again.",
      502
    );
  }

  const character = {
    name: clampText(parsed.name, 60) || "New character",
    category: oneOf(parsed.category, CHARACTER_CATEGORIES, category),
    role: oneOf(parsed.role, CHARACTER_ROLES, role),
    appearance: clampText(parsed.appearance, 1200),
    personality: clampText(parsed.personality, 1200),
    backstory: clampText(parsed.backstory, 1400),
    interests: stringList(parsed.interests, 8, 60),
    speakingStyle: clampText(parsed.speakingStyle, 500),
    language: clampText(parsed.language, 40) || "English",
    imagePrompt: clampText(parsed.imagePrompt, 1200),
  };

  return responseJson({ success: true, character }, 200, cors);
}

function envString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return "";
}

/** First http(s) image address in whatever shape the provider answered with. */
function firstImageOutput(payload) {
  const candidates = [
    payload?.data?.outputs,
    payload?.outputs,
    payload?.data?.output,
    payload?.output,
  ];

  for (const value of candidates) {
    if (typeof value === "string" && value.startsWith("http")) return value;
    if (Array.isArray(value)) {
      const hit = value.find(
        (item) => typeof item === "string" && item.startsWith("http")
      );
      if (hit) return hit;
    }
  }

  return null;
}

/**
 * Asks the image provider for one portrait and returns its address.
 *
 * The provider and model are configuration, not code: IMAGE_API_KEY,
 * IMAGE_MODEL (and optionally IMAGE_API_BASE) are Worker secrets/vars. The
 * default base URL is the documented WaveSpeedAI endpoint.
 */
async function requestCharacterImage({
  apiKey,
  baseUrl,
  model,
  prompt,
  images = [],
}) {
  // Model ids look like "google/nano-banana-2.1/text-to-image": the slashes are
  // part of the path, so only the segments may be escaped.
  const modelPath = String(model)
    .split("/")
    .filter(Boolean)
    .map((part) => encodeURIComponent(part))
    .join("/");

  const submit = await fetch(`${baseUrl}/${modelPath}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      prompt,
      // Reference images only exist for models that accept them; the text-only
      // endpoint rejects an empty array, so it is omitted entirely.
      ...(images.length ? { images } : {}),
      aspect_ratio: "3:4",
      output_format: "jpeg",
    }),
  });

  if (!submit.ok) {
    const detail = (await submit.text().catch(() => "")).slice(0, 300);
    console.error(`Image provider responded ${submit.status}: ${detail}`);
    throw new AiError(
      submit.status === 401 || submit.status === 403
        ? "AI_NOT_CONFIGURED"
        : "AI_SERVICE_UNAVAILABLE",
      submit.status === 401 || submit.status === 403
        ? "The image provider rejected its key. Please check the Worker secret."
        : "The image service is temporarily unavailable. Please try again.",
      503
    );
  }

  let payload = await submit.json().catch(() => null);
  let output = firstImageOutput(payload);

  // Some models answer with a prediction id and finish asynchronously.
  const predictionId = payload?.data?.id ? String(payload.data.id) : "";
  const failedStatuses = ["failed", "cancelled", "canceled", "timeout", "deleted"];
  for (let attempt = 0; attempt < 30 && !output && predictionId; attempt += 1) {
    await sleep(2000);
    const poll = await fetch(
      `${baseUrl}/predictions/${encodeURIComponent(predictionId)}/result`,
      { headers: { Authorization: `Bearer ${apiKey}` } }
    );
    if (!poll.ok) continue;
    payload = await poll.json().catch(() => null);
    output = firstImageOutput(payload);
    const status = String(payload?.data?.status || "").toLowerCase();
    if (failedStatuses.includes(status)) break;
  }

  if (!output) {
    throw new AiError(
      "AI_SERVICE_UNAVAILABLE",
      "The image service returned no picture. Please try again.",
      502
    );
  }

  return output;
}

/**
 * Validates up to three character reference pictures and confirms they belong
 * to the caller. Returns their R2 keys, or the error to report.
 */
async function resolveCharacterReferences(env, user, value) {
  if (value === undefined || value === null) return { keys: [] };

  if (!Array.isArray(value)) {
    return {
      error: new AiError(
        "INVALID_REQUEST",
        "referenceKeys must be a list of uploaded pictures.",
        400
      ),
    };
  }

  const keys = value
    .map((item) => clampText(item, 300))
    .filter(Boolean)
    .slice(0, 3);

  for (const key of keys) {
    if (key.includes("\\") || !key.startsWith(`${user.sub}/`)) {
      return {
        error: new AiError(
          "FORBIDDEN",
          "You can only use your own pictures as a reference.",
          403
        ),
      };
    }

    const object = await env.MEDIA_BUCKET.head(key);
    if (!object) {
      return {
        error: new AiError(
          "MEDIA_NOT_FOUND",
          "The reference picture could not be found. Please upload it again.",
          404
        ),
      };
    }

    const contentType = (object.httpMetadata?.contentType || "")
      .split(";")[0]
      .trim()
      .toLowerCase();

    if (!contentType.startsWith("image/")) {
      return {
        error: new AiError(
          "INVALID_REQUEST",
          "Reference pictures must be images.",
          415
        ),
      };
    }
  }

  return { keys };
}

async function handleCharacterImage(request, env, user, token, cors) {
  const body = await readAiJsonBody(request);
  const prompt = clampText(body.prompt, 1500);
  const characterId = clampText(body.characterId, 80) || crypto.randomUUID();

  if (!prompt) {
    throw new AiError(
      "INVALID_REQUEST",
      "A portrait description is required.",
      400
    );
  }
  if (!/^[A-Za-z0-9_-]+$/.test(characterId)) {
    throw new AiError("INVALID_REQUEST", "Invalid characterId.", 400);
  }

  await enforceAiRateLimit(env, user.sub);

  const apiKey = envString(env.IMAGE_API_KEY, env.WAVESPEED_API_KEY);
  const model = envString(env.IMAGE_MODEL);
  const baseUrl = envString(
    env.IMAGE_API_BASE,
    "https://api.wavespeed.ai/api/v3"
  ).replace(/\/+$/, "");

  if (!apiKey) {
    throw new AiError(
      "AI_NOT_CONFIGURED",
      "Portrait generation needs IMAGE_API_KEY (or WAVESPEED_API_KEY) on the server.",
      503
    );
  }
  // Reference pictures switch the portrait to the edit model, which keeps the
  // face from the upload instead of inventing one.
  const tf = await resolveCharacterReferences(env, user, body.referenceKeys);

  if (tf.error) {
    throw tf.error;
  }

  // A text portrait needs IMAGE_MODEL. A reference portrait falls back to the
  // documented edit model, so the two paths can be configured independently
  // instead of both being blocked when only one model is set.
  const usesReferences = tf.keys.length > 0;
  if (!model && !usesReferences) {
    throw new AiError(
      "AI_NOT_CONFIGURED",
      "Set IMAGE_MODEL to the image provider's model id before generating portraits.",
      503
    );
  }

  const origin = new URL(request.url).origin;
  const referenceUrls = [];

  for (const referenceKey of tf.keys) {
    const url = await signedMediaUrl(env, origin, referenceKey);
    if (!url) {
      throw new AiError(
        "AI_NOT_CONFIGURED",
        "Portrait generation from a photo needs MEDIA_SIGNING_KEY on the server.",
        503
      );
    }
    referenceUrls.push(url);
  }

  const editModel =
    referenceUrls.length > 0
      ? envString(env.IMAGE_EDIT_MODEL, "google/nano-banana-2.1/edit")
      : model;

  const imageUrl = await requestCharacterImage({
    apiKey,
    baseUrl,
    model: editModel,
    prompt,
    images: referenceUrls,
  });

  const download = await fetch(imageUrl);
  if (!download.ok) {
    throw new AiError(
      "AI_SERVICE_UNAVAILABLE",
      "The generated portrait could not be downloaded. Please try again.",
      502
    );
  }

  const contentType = (download.headers.get("content-type") || "image/png")
    .split(";")[0]
    .trim()
    .toLowerCase();
  const extension = contentType.includes("webp")
    ? "webp"
    : contentType.includes("jpeg") || contentType.includes("jpg")
      ? "jpg"
      : "png";

  const bytes = await download.arrayBuffer();
  if (bytes.byteLength === 0) {
    throw new AiError(
      "AI_SERVICE_UNAVAILABLE",
      "The generated portrait was empty. Please try again.",
      502
    );
  }

  const key = `${user.sub}/characters/${characterId}.${extension}`;

  await env.MEDIA_BUCKET.put(key, bytes, {
    httpMetadata: { contentType },
    customMetadata: {
      ownerUid: user.sub,
      purpose: "character",
      category: "image",
      createdAtMs: String(Date.now()),
    },
  });

  return responseJson(
    {
      success: true,
      key,
      url: `${new URL(request.url).origin}/media/${key}`,
      contentType,
    },
    200,
    cors
  );
}

async function handleTranscribeRecording(request, env, user, token, cors) {
  const body = await readAiJsonBody(request);
  const { conversationId, conversationType } = readConversation(body);

  const mediaKey = clampText(body.mediaKey, 320);
  if (!mediaKey || mediaKey.length > 300 || mediaKey.includes("\\")) {
    throw new AiError(
      "INVALID_REQUEST",
      "A valid media key is required.",
      400
    );
  }

  // Ownership first: a caller may only transcribe their own upload.
  if (!mediaKey.startsWith(`${user.sub}/`)) {
    throw new AiError(
      "FORBIDDEN",
      "You can only transcribe your own recordings.",
      403
    );
  }

  const chunkIndex = Number(body.chunkIndex ?? 0);
  if (!Number.isInteger(chunkIndex) || chunkIndex < 0 || chunkIndex > 10000) {
    throw new AiError(
      "INVALID_REQUEST",
      "chunkIndex must be a non-negative integer.",
      400
    );
  }

  const language = clampText(body.language, 12).toLowerCase();

  await authorizeConversation(conversationId, conversationType, user, token);
  await enforceAiRateLimit(env, user.sub);

  const object = await env.MEDIA_BUCKET.get(mediaKey);
  if (!object) {
    throw new AiError(
      "MEDIA_NOT_FOUND",
      "The uploaded recording could not be found. Please upload it again.",
      404
    );
  }

  const contentType = (object.httpMetadata?.contentType || "")
    .split(";")[0]
    .trim()
    .toLowerCase();

  if (!contentType.startsWith("audio/")) {
    throw new AiError(
      "INVALID_REQUEST",
      "Only audio recordings can be transcribed.",
      415
    );
  }

  const size = Number(object.size) || 0;
  if (size <= 0 || size > MAX_STT_BYTES) {
    throw new AiError(
      "INVALID_REQUEST",
      `Each recording part must be between 1 byte and ${Math.floor(
        MAX_STT_BYTES / 1024 / 1024
      )} MB.`,
      413
    );
  }

  const bytes = await object.arrayBuffer();
  const extensionMatch = mediaKey.match(/\.([a-zA-Z0-9]{1,10})$/);
  const fileName = `recording.${extensionMatch ? extensionMatch[1].toLowerCase() : "m4a"}`;

  const transcription = await requestGroqTranscription(env, {
    bytes,
    contentType,
    fileName,
    language: language || null,
  });

  return responseJson(
    {
      provider: "groq",
      model: GROQ_STT_MODEL,
      chunkIndex,
      ...transcription,
    },
    200,
    cors
  );
}

const TRANSCRIPT_NOTES_SYSTEM_PROMPT = [
  "You condense one section of a call transcript into factual notes.",
  "Return plain text only: no markdown, no headings, no JSON.",
  "Keep names, numbers, dates, decisions, action items and deadlines exactly as stated.",
  "Keep the order of the discussion and mark the speaker when the transcript names one.",
  "Never invent anything that is not in the section.",
  "Keep the language of the transcript.",
].join("\n");

/** Splits a transcript into sections near a line boundary. */
function splitTranscriptSections(transcript) {
  const sections = [];
  let rest = transcript;

  while (rest.length > 0 && sections.length < MAX_TRANSCRIPT_SECTIONS) {
    if (rest.length <= TRANSCRIPT_SECTION_CHARS) {
      sections.push(rest);
      break;
    }

    let cut = rest.lastIndexOf("\n", TRANSCRIPT_SECTION_CHARS);
    if (cut < TRANSCRIPT_SECTION_CHARS * 0.6) {
      cut = rest.lastIndexOf(". ", TRANSCRIPT_SECTION_CHARS);
    }
    if (cut < TRANSCRIPT_SECTION_CHARS * 0.6) {
      cut = TRANSCRIPT_SECTION_CHARS;
    }

    sections.push(rest.slice(0, cut));
    rest = rest.slice(cut);
  }

  return sections;
}

/**
 * Condenses a long call transcript into notes that fit the minutes prompt.
 * Sections run with bounded concurrency; order is preserved because results
 * are written back by index.
 */
async function condenseTranscript(env, transcript) {
  const sections = splitTranscriptSections(transcript);
  const notes = new Array(sections.length).fill("");

  for (
    let start = 0;
    start < sections.length;
    start += TRANSCRIPT_SECTION_CONCURRENCY
  ) {
    const batch = sections.slice(start, start + TRANSCRIPT_SECTION_CONCURRENCY);
    const results = await Promise.all(
      batch.map((section, offset) =>
        requestGroqCompletion(env, {
          systemPrompt: TRANSCRIPT_NOTES_SYSTEM_PROMPT,
          userPrompt: `Call transcript section ${start + offset + 1} of ${
            sections.length
          }:\n\n${section}`,
          schema: null,
          schemaName: null,
          temperature: 0.2,
          maxCompletionTokens: 900,
          timeoutMs: AI_TIMEOUTS.transcriptSection,
        })
      )
    );

    results.forEach((result, offset) => {
      notes[start + offset] = result;
    });
  }

  return notes.filter(Boolean).join("\n\n");
}

function aiErrorResponse(error, cors) {
  if (error instanceof AiError) {
    return responseJson(
      {
        error: {
          code: error.code,
          message: error.message,
          ...(error.retryAfterSeconds
            ? { retryAfterSeconds: error.retryAfterSeconds }
            : {}),
        },
      },
      error.status,
      cors
    );
  }

  // Never surface internal details (stack, provider body, key state) to callers.
  console.error(`AI request failed: ${error?.name || "error"}`);
  return responseJson(
    {
      error: {
        code: "INTERNAL",
        message: "The AI request could not be completed. Please try again.",
      },
    },
    500,
    cors
  );
}

async function handleAiRoute(request, env, user, token, url, cors) {
  try {
    if (request.method !== "POST") {
      return responseJson(
        {
          error: {
            code: "INVALID_REQUEST",
            message: "AI routes only accept POST requests.",
          },
        },
        405,
        { ...cors, Allow: "POST, OPTIONS" }
      );
    }

    switch (url.pathname) {
      case "/ai/summarize-chat":
        return await handleSummarizeChat(request, env, user, token, cors);
      case "/ai/generate-meeting-minutes":
        return await handleGenerateMinutes(request, env, user, token, cors);
      case "/ai/smart-replies":
        return await handleSmartReplies(request, env, user, token, cors);
      case "/ai/transcribe":
        return await handleTranscribeRecording(request, env, user, token, cors);
      case "/ai/characters/draft":
        return await handleCharacterDraft(request, env, user, token, cors);
      case "/ai/characters/image":
        return await handleCharacterImage(request, env, user, token, cors);
      default:
        return responseJson(
          {
            error: {
              code: "NOT_FOUND",
              message: "AI route not found.",
            },
          },
          404,
          cors
        );
    }
  } catch (error) {
    return aiErrorResponse(error, cors);
  }
}

export default {
  async fetch(request, env) {
    const cors = corsHeaders(request);
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }

    if (url.pathname === "/health" && request.method === "GET") {
      return responseJson(
        {
          status: "ok",
          service: "yokedin-media-api",
          build: WORKER_BUILD,
          features: WORKER_FEATURES,
        },
        200,
        cors
      );
    }

    // Signed media links are fetched by an image provider, which cannot send a
    // Firebase token, so they are served before the authentication gate.
    if (
      request.method === "GET" &&
      url.pathname.startsWith("/media/") &&
      (url.searchParams.has("sig") || url.searchParams.has("exp"))
    ) {
      return serveSignedMedia(request, env, url, cors);
    }

    if (!["GET", "POST", "DELETE"].includes(request.method)) {
      return responseJson(
        { error: "Method not allowed" },
        405,
        { ...cors, Allow: "GET, POST, DELETE, OPTIONS" }
      );
    }

    const authorization = request.headers.get("Authorization") || "";
    const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);
    const isMediaGet =
      request.method === "GET" && url.pathname.startsWith("/media/");
    const queryToken = isMediaGet ? url.searchParams.get("authToken") : null;
    const token = tokenMatch?.[1] || queryToken;
    const user = await verifyFirebaseToken(request);

    if (!user || !token) {
      return responseJson(
        { error: "Authentication required. Please sign in again." },
        401,
        cors
      );
    }

    // -------------------- AI ROUTES --------------------
    // Dispatched before the media path parser, in its own error boundary, so
    // the existing media behaviour and error copy below are untouched.
    if (url.pathname.startsWith("/ai/")) {
      return handleAiRoute(request, env, user, token, url, cors);
    }

    try {
      // -------------------- UPLOAD --------------------
      if (url.pathname === "/upload" && request.method === "POST") {
        const contentType = (
          request.headers.get("Content-Type") || ""
        ).split(";")[0].trim().toLowerCase();

        if (!ALLOWED_TYPES.has(contentType)) {
          return responseJson(
            { error: "This file type is not supported." },
            415,
            cors
          );
        }

        const purpose = request.headers.get("X-Media-Purpose") || "profile";
        if (!["profile", "chat", "group", "character"].includes(purpose)) {
          return responseJson({ error: "Invalid media purpose." }, 400, cors);
        }

        const chatId = request.headers.get("X-Chat-Id") || "";
        const groupId = request.headers.get("X-Group-Id") || "";
        const characterId = request.headers.get("X-Character-Id") || "";

        if (purpose === "chat") {
          if (!chatId || !(await isChatParticipant(chatId, user.sub, token))) {
            return responseJson(
              { error: "You are not a participant in this chat." },
              403,
              cors
            );
          }
        }

        if (purpose === "group") {
          if (!groupId || !(await isGroupMember(groupId, user.sub, token))) {
            return responseJson(
              { error: "You are not a member of this group." },
              403,
              cors
            );
          }
        }

        if (
          (purpose !== "chat" && chatId) ||
          (purpose !== "group" && groupId)
        ) {
          return responseJson(
            { error: "Unexpected conversation identifier." },
            400,
            cors
          );
        }

        // A character reference picture belongs to one character and can only
        // be used to build that character's identity.
        if (purpose === "character") {
          if (!/^[A-Za-z0-9_-]{1,80}$/.test(characterId)) {
            return responseJson(
              { error: "A valid character ID is required for character photos." },
              400,
              cors
            );
          }
        } else if (characterId) {
          return responseJson(
            { error: "Unexpected character identifier." },
            400,
            cors
          );
        }

        const inferredCategory = categoryForContentType(contentType);
        const requestedCategory =
          request.headers.get("X-Media-Category") || inferredCategory;

        if (
          !inferredCategory ||
          !["image", "video", "voice", "audio", "document"].includes(requestedCategory)
        ) {
          return responseJson({ error: "Invalid media category." }, 400, cors);
        }

        // The declared category must agree with the MIME type.
        if (
          requestedCategory !== inferredCategory &&
          !(inferredCategory === "audio" && requestedCategory === "voice")
        ) {
          return responseJson(
            { error: "The media category does not match the file type." },
            400,
            cors
          );
        }

        if (purpose === "profile" && requestedCategory !== "image") {
          return responseJson(
            { error: "Profile uploads must be images." },
            415,
            cors
          );
        }

        if (purpose === "character" && requestedCategory !== "image") {
          return responseJson(
            { error: "Character photos must be images." },
            415,
            cors
          );
        }

        if (purpose !== "profile" && requestedCategory === "image" &&
            !contentType.startsWith("image/")) {
          return responseJson({ error: "Invalid image type." }, 415, cors);
        }

        const maxSize = SIZE_LIMITS[requestedCategory];
        const lengthHeader = request.headers.get("Content-Length");
        const declaredLength = lengthHeader ? Number(lengthHeader) : null;

        if (
          declaredLength !== null &&
          (!Number.isFinite(declaredLength) ||
            declaredLength <= 0 ||
            declaredLength > maxSize)
        ) {
          return responseJson(
            { error: `File exceeds the ${Math.floor(maxSize / 1024 / 1024)} MB limit.` },
            413,
            cors
          );
        }

        const data = await request.arrayBuffer();
        if (data.byteLength === 0 || data.byteLength > maxSize) {
          return responseJson(
            { error: `File must be between 1 byte and ${Math.floor(maxSize / 1024 / 1024)} MB.` },
            413,
            cors
          );
        }

        const originalName = request.headers.get("X-File-Name") || "upload";
        const extension = getExtension(originalName, contentType);
        // Reference pictures are grouped per character so they can be removed
        // together, and so they never collide with chat or profile objects.
        const key =
          purpose === "character"
            ? `${user.sub}/characters/${characterId}/ref-${crypto.randomUUID()}.${extension}`
            : `${user.sub}/${crypto.randomUUID()}.${extension}`;
        const storedPurpose =
          purpose === "character" ? "character_reference" : purpose;
        const expiryDuration = EXPIRY_MS[requestedCategory];
        const expiresAtMs = expiryDuration === null
          ? null
          : Date.now() + expiryDuration;

        await env.MEDIA_BUCKET.put(key, data, {
          httpMetadata: { contentType },
          customMetadata: {
            ownerUid: user.sub,
            purpose: storedPurpose,
            category: requestedCategory,
            createdAtMs: String(Date.now()),
            ...(expiresAtMs === null ? {} : { expiresAtMs: String(expiresAtMs) }),
            ...(purpose === "chat" ? { chatId } : {}),
            ...(purpose === "group" ? { groupId } : {}),
            ...(purpose === "character" ? { characterId } : {}),
          },
        });

        return responseJson(
          {
            success: true,
            key,
            url: `${url.origin}/media/${key}`,
            contentType,
            category: requestedCategory,
            size: data.byteLength,
            expiresAtMs,
          },
          201,
          cors
        );
      }

      // -------------------- MEDIA ROUTES --------------------
      const key = safeKeyFromPath(url.pathname);
      if (!key) {
        return responseJson({ error: "Route not found" }, 404, cors);
      }

      if (request.method === "DELETE") {
        if (!key.startsWith(`${user.sub}/`)) {
          return responseJson(
            { error: "You can only delete your own uploads." },
            403,
            cors
          );
        }

        const existing = await env.MEDIA_BUCKET.head(key);
        if (!existing) {
          return responseJson({ error: "Media not found" }, 404, cors);
        }

        if (existing.customMetadata?.ownerUid !== user.sub) {
          return responseJson(
            { error: "You can only delete your own uploads." },
            403,
            cors
          );
        }

        await env.MEDIA_BUCKET.delete(key);
        return responseJson({ success: true }, 200, cors);
      }

      if (request.method === "GET") {
        const object = await env.MEDIA_BUCKET.get(key);
        if (!object) {
          return responseJson({ error: "Media not found" }, 404, cors);
        }

        const metadata = object.customMetadata || {};
        const purpose = metadata.purpose;

        // Block access immediately at expiry, even before scheduled deletion.
        if (mediaHasExpired(metadata)) {
          return responseJson(
            {
              error: "Media expired.",
              expired: true,
              category: metadata.category || "unknown",
            },
            410,
            cors
          );
        }

        if (purpose === "profile") {
          // Any signed-in user may view a profile picture.
        } else if (purpose === "character") {
          // Character portraits are readable by any signed-in user; the
          // document that points at one decides who may use the character.
        } else if (purpose === "character_reference") {
          // A reference photo of a real face stays private to its owner.
          if (!key.startsWith(`${user.sub}/`)) {
            return responseJson(
              { error: "You are not allowed to view this character photo." },
              403,
              cors
            );
          }
        } else if (purpose === "chat") {
          if (
            !metadata.chatId ||
            !(await isChatParticipant(metadata.chatId, user.sub, token))
          ) {
            return responseJson(
              { error: "You are not allowed to view this chat media." },
              403,
              cors
            );
          }
        } else if (purpose === "group") {
          if (
            !metadata.groupId ||
            !(await isGroupMember(metadata.groupId, user.sub, token))
          ) {
            return responseJson(
              { error: "You are not allowed to view this group media." },
              403,
              cors
            );
          }
        } else if (
          !purpose &&
          key.split("/").length === 2 &&
          key.startsWith(`${metadata.ownerUid}/`)
        ) {
          // Backward compatibility for legacy profile pictures.
        } else {
          return responseJson(
            { error: "Media access is not configured." },
            403,
            cors
          );
        }

        const headers = new Headers(cors);
        object.writeHttpMetadata(headers);
        headers.set("ETag", object.httpEtag);
        headers.set("Cache-Control", "private, no-store");
        headers.set("X-Content-Type-Options", "nosniff");

        return new Response(object.body, { status: 200, headers });
      }

      return responseJson({ error: "Route not found" }, 404, cors);
    } catch (error) {
      console.error("Media API request failed");
      return responseJson(
        { error: "The media request could not be completed." },
        500,
        cors
      );
    }
  },

  // -------------------- SCHEDULED R2 CLEANUP --------------------
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(cleanupExpiredMedia(env));
  },
};

async function cleanupExpiredMedia(env) {
  let cursor;
  let deletedCount = 0;

  try {
    do {
      const page = await env.MEDIA_BUCKET.list({
        limit: 1000,
        ...(cursor ? { cursor } : {}),
        include: ["customMetadata"],
      });

      const expiredKeys = [];
      const now = Date.now();

      for (const object of page.objects) {
        const metadata = object.customMetadata || {};
        const expiry = Number(metadata.expiresAtMs);

        if (
          Number.isFinite(expiry) &&
          expiry > 0 &&
          now >= expiry
        ) {
          expiredKeys.push(object.key);
        }
      }

      if (expiredKeys.length > 0) {
        await env.MEDIA_BUCKET.delete(expiredKeys);
        deletedCount += expiredKeys.length;
      }

      if (!page.truncated) break;
      cursor = page.cursor;
    } while (cursor);

    console.log(`Expired media cleanup completed. Deleted: ${deletedCount}`);
  } catch (error) {
    console.error("Expired media cleanup failed");
    throw error;
  }
}