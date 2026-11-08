import {logger} from "firebase-functions";
import {
  CallableRequest,
  HttpsError,
  onCall,
} from "firebase-functions/v2/https";
import {
  ChatMessage,
  GROQ_MODEL,
  MAX_INPUT_CHARS,
  SchemaRejectedError,
  callGroqChat,
  groqApiKey,
} from "./groqClient";
import {
  MINUTES_JSON_FALLBACK_INSTRUCTION,
  MINUTES_SCHEMA,
  MINUTES_SYSTEM_PROMPT,
  REPLIES_JSON_FALLBACK_INSTRUCTION,
  REPLIES_SCHEMA,
  REPLIES_SYSTEM_PROMPT,
  SUMMARY_SYSTEM_PROMPT,
  buildMinutesPrompt,
  buildRepliesPrompt,
  buildSummaryPrompt,
} from "./prompts";

/** Region shared by the callables and AIConfig.functionsRegion in Flutter. */
const REGION = "us-central1";

/**
 * Every callable below requires a signed-in Firebase user and the
 * Secret Manager-backed Groq key.
 */
const baseOptions = {
  region: REGION,
  secrets: [groqApiKey],
};

interface NormalizedActionItem {
  task: string;
  assignee: string | null;
  dueDate: string | null;
}

interface NormalizedTranscriptSegment {
  speaker: string;
  text: string;
  timestamp: string;
}

interface NormalizedMinute {
  title: string;
  summary: string;
  keyDecisions: string[];
  actionItems: NormalizedActionItem[];
  transcript: NormalizedTranscriptSegment[];
}

interface StructuredRequest {
  schemaName: string;
  schema: Record<string, unknown>;
  messages: ChatMessage[];
  fallbackInstruction: string;
  temperature: number;
  maxCompletionTokens: number;
  timeoutMs: number;
  maxAttempts: number;
}

const requireAuth = (request: CallableRequest): string => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError(
      "unauthenticated",
      "Please sign in again to use AI features."
    );
  }
  return uid;
};

const readBody = (request: CallableRequest): Record<string, unknown> => {
  const data: unknown = request.data;
  if (data === null || typeof data !== "object" || Array.isArray(data)) {
    return {};
  }
  return data as Record<string, unknown>;
};

const readRequiredString = (
  data: Record<string, unknown>,
  field: string,
  maxLength: number
): string => {
  const value = data[field];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError(
      "invalid-argument",
      `The "${field}" field is required.`
    );
  }
  const trimmed = value.trim();
  if (trimmed.length > maxLength) {
    throw new HttpsError(
      "invalid-argument",
      `The "${field}" field is too long (${trimmed.length} of ` +
        `${maxLength} characters allowed). Please shorten it and retry.`
    );
  }
  return trimmed;
};

const readStringList = (value: unknown, limit: number): string[] => {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0)
    .slice(0, limit);
};

const readNameMap = (
  value: unknown,
  limit: number
): Record<string, string> => {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, name]) => typeof name === "string")
    .slice(0, limit)
    .map(([key, name]) => [key, (name as string).trim()] as const);
  return Object.fromEntries(entries);
};

const readDurationSeconds = (value: unknown): number => {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return 0;
  }
  return Math.min(Math.round(value), 86400);
};

const asText = (
  value: unknown,
  fallback: string,
  maxLength: number
): string => {
  if (typeof value !== "string") return fallback;
  const trimmed = value.trim();
  if (trimmed.length === 0) return fallback;
  return trimmed.slice(0, maxLength);
};

const asNullableText = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
};

const readObjectList = (
  value: unknown
): Array<Record<string, unknown>> => {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is Record<string, unknown> => {
      return item !== null &&
        typeof item === "object" &&
        !Array.isArray(item);
    })
    .slice(0, 100);
};

const stripCodeFences = (text: string): string => {
  let trimmed = text.trim();
  if (trimmed.startsWith("```")) {
    const firstBreak = trimmed.indexOf("\n");
    trimmed = firstBreak === -1 ? "" : trimmed.slice(firstBreak + 1);
  }
  if (trimmed.endsWith("```")) {
    trimmed = trimmed.slice(0, trimmed.length - 3);
  }
  return trimmed.trim();
};

const parseJsonObject = (
  content: string,
  schemaName: string
): Record<string, unknown> => {
  const cleaned = stripCodeFences(content);
  try {
    const parsed: unknown = JSON.parse(cleaned);
    if (
      parsed !== null &&
      typeof parsed === "object" &&
      !Array.isArray(parsed)
    ) {
      return parsed as Record<string, unknown>;
    }
  } catch (error: unknown) {
    logger.error("groq.invalid_json", {schema: schemaName, error});
  }
  throw new HttpsError(
    "internal",
    "The AI returned an unreadable response. Please try again."
  );
};

/**
 * Fails loudly when the model ran out of completion tokens.
 *
 * A truncated JSON payload would otherwise surface as an unreadable
 * response, which hides the real cause.
 *
 * @param {string | null} finishReason The provider finish reason.
 * @param {string} schemaName The schema being generated.
 */
const assertCompleteResponse = (
  finishReason: string | null,
  schemaName: string
): void => {
  if (finishReason !== "length") return;
  logger.warn("groq.truncated_response", {schema: schemaName});
  throw new HttpsError(
    "resource-exhausted",
    "The AI response was cut off before it finished. Please shorten the " +
      "conversation and try again."
  );
};

/**
 * Requests JSON from Groq.
 *
 * Strict json_schema mode is used first. If the provider rejects the schema
 * itself (a 400 mentioning schema validation), the request is retried once in
 * plain JSON mode with an explicit shape instruction, and the fallback is
 * logged instead of being hidden.
 *
 * @param {StructuredRequest} request The schema, messages and limits.
 * @return {Promise<Record<string, unknown>>} The parsed JSON object.
 */
const completeStructuredJson = async (
  request: StructuredRequest
): Promise<Record<string, unknown>> => {
  let content: string;
  try {
    const result = await callGroqChat({
      messages: request.messages,
      jsonSchema: {name: request.schemaName, schema: request.schema},
      temperature: request.temperature,
      maxCompletionTokens: request.maxCompletionTokens,
      timeoutMs: request.timeoutMs,
      maxAttempts: request.maxAttempts,
    });
    assertCompleteResponse(result.finishReason, request.schemaName);
    content = result.content;
  } catch (error: unknown) {
    if (!(error instanceof SchemaRejectedError)) {
      throw error;
    }
    logger.warn("groq.schema_rejected_fallback", {
      schema: request.schemaName,
      detail: error.message,
    });
    const result = await callGroqChat({
      messages: [
        ...request.messages,
        {role: "user" as const, content: request.fallbackInstruction},
      ],
      jsonObject: true,
      temperature: request.temperature,
      maxCompletionTokens: request.maxCompletionTokens,
      timeoutMs: request.timeoutMs,
      maxAttempts: 1,
    });
    assertCompleteResponse(result.finishReason, request.schemaName);
    content = result.content;
  }
  return parseJsonObject(content, request.schemaName);
};

const normalizeMinute = (
  parsed: Record<string, unknown>,
  fallbackTitle: string
): NormalizedMinute => {
  const actionItems = readObjectList(parsed["actionItems"]).map((item) => ({
    task: asText(item["task"], "Unnamed task", 500),
    assignee: asNullableText(item["assignee"]),
    dueDate: asNullableText(item["dueDate"]),
  }));
  const transcript = readObjectList(parsed["transcript"]).map((segment) => ({
    speaker: asText(segment["speaker"], "Participant", 120),
    text: asText(segment["text"], "", 4000),
    timestamp: asText(segment["timestamp"], "00:00", 20),
  }));
  return {
    title: asText(parsed["title"], fallbackTitle, 200),
    summary: asText(parsed["summary"], "", 8000),
    keyDecisions: readStringList(parsed["keyDecisions"], 50),
    actionItems,
    transcript,
  };
};

const emptyModelResponse = (message: string): HttpsError => {
  return new HttpsError("internal", message);
};

/**
 * Generates structured meeting minutes.
 *
 * The Flutter client still writes the result to Firestore through
 * MeetingMinutesService, so the existing data model and rules are unchanged.
 */
export const generateMeetingMinutes = onCall(
  {...baseOptions, timeoutSeconds: 120, memory: "512MiB"},
  async (request) => {
    const uid = requireAuth(request);
    const data = readBody(request);

    const conversationId = readRequiredString(data, "conversationId", 200);
    const conversationType =
      readRequiredString(data, "conversationType", 20);
    const conversationTitle =
      readRequiredString(data, "conversationTitle", 200);
    const rawContent =
      readRequiredString(data, "rawContent", MAX_INPUT_CHARS);
    const participantNames = readNameMap(data["participantNames"], 50);
    const durationSeconds = readDurationSeconds(data["durationSeconds"]);

    logger.info("ai.minutes.request", {
      uid,
      conversationId,
      conversationType,
      contentCharacters: rawContent.length,
    });

    const parsed = await completeStructuredJson({
      schemaName: "meeting_minutes",
      schema: MINUTES_SCHEMA,
      messages: [
        {role: "system", content: MINUTES_SYSTEM_PROMPT},
        {
          role: "user",
          content: buildMinutesPrompt({
            conversationTitle,
            conversationType,
            participantNames: Object.values(participantNames),
            durationSeconds,
            rawContent,
          }),
        },
      ],
      fallbackInstruction: MINUTES_JSON_FALLBACK_INSTRUCTION,
      temperature: 0.2,
      maxCompletionTokens: 3000,
      timeoutMs: 30000,
      maxAttempts: 2,
    });

    const minute = normalizeMinute(parsed, `Call with ${conversationTitle}`);
    if (minute.summary.length === 0) {
      throw emptyModelResponse(
        "The AI response did not include a summary. Please try again."
      );
    }

    logger.info("ai.minutes.success", {
      uid,
      conversationId,
      actionItems: minute.actionItems.length,
      transcriptSegments: minute.transcript.length,
    });

    return {
      provider: "groq",
      model: GROQ_MODEL,
      minute: {
        title: minute.title,
        summary: minute.summary,
        keyDecisions: minute.keyDecisions,
        actionItems: minute.actionItems,
        transcript: minute.transcript,
      },
    };
  }
);

/** Summarises recent private or group chat messages. */
export const summarizeChat = onCall(
  {...baseOptions, timeoutSeconds: 90, memory: "256MiB"},
  async (request) => {
    const uid = requireAuth(request);
    const data = readBody(request);

    const conversationTitle =
      readRequiredString(data, "conversationTitle", 200);
    const messages = readStringList(data["messages"], 30);
    if (messages.length === 0) {
      throw new HttpsError(
        "invalid-argument",
        "There are no recent messages to summarize."
      );
    }

    const joined = messages.join("\n");
    if (joined.length > MAX_INPUT_CHARS) {
      throw new HttpsError(
        "invalid-argument",
        "This conversation is too long to summarize in one request " +
          `(${joined.length} of ${MAX_INPUT_CHARS} characters). ` +
          "Please try again with fewer messages."
      );
    }

    logger.info("ai.summary.request", {
      uid,
      messageCount: messages.length,
      contentCharacters: joined.length,
    });

    const result = await callGroqChat({
      messages: [
        {role: "system", content: SUMMARY_SYSTEM_PROMPT},
        {
          role: "user",
          content: buildSummaryPrompt(conversationTitle, joined),
        },
      ],
      temperature: 0.4,
      maxCompletionTokens: 800,
      timeoutMs: 20000,
      maxAttempts: 2,
    });

    const summary = result.content.trim();
    if (summary.length === 0) {
      throw emptyModelResponse(
        "The AI returned an empty summary. Please try again."
      );
    }

    logger.info("ai.summary.success", {
      uid,
      summaryCharacters: summary.length,
    });

    return {provider: "groq", model: GROQ_MODEL, summary};
  }
);

/** Suggests three contextual smart replies. */
export const smartReplies = onCall(
  {...baseOptions, timeoutSeconds: 60, memory: "256MiB"},
  async (request) => {
    const uid = requireAuth(request);
    const data = readBody(request);

    const recentMessages = readStringList(data["recentMessages"], 10);
    if (recentMessages.length === 0) {
      return {
        provider: "groq",
        model: GROQ_MODEL,
        replies: [] as string[],
      };
    }

    const parsed = await completeStructuredJson({
      schemaName: "smart_replies",
      schema: REPLIES_SCHEMA,
      messages: [
        {role: "system", content: REPLIES_SYSTEM_PROMPT},
        {
          role: "user",
          content: buildRepliesPrompt(recentMessages.join("\n")),
        },
      ],
      fallbackInstruction: REPLIES_JSON_FALLBACK_INSTRUCTION,
      temperature: 0.7,
      maxCompletionTokens: 300,
      timeoutMs: 12000,
      maxAttempts: 2,
    });

    const replies = readStringList(parsed["replies"], 3);
    logger.info("ai.replies.success", {uid, replyCount: replies.length});

    return {provider: "groq", model: GROQ_MODEL, replies};
  }
);
