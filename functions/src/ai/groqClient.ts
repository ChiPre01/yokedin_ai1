import {logger} from "firebase-functions";
import {defineSecret} from "firebase-functions/params";
import {HttpsError} from "firebase-functions/v2/https";

/**
 * Secret Manager-backed Groq API key.
 * Set with: firebase functions:secrets:set GROQ_API_KEY
 * It is only read inside deployed functions and never sent to clients.
 */
export const groqApiKey = defineSecret("GROQ_API_KEY");

/** OpenAI-compatible Groq chat completions endpoint. */
export const GROQ_CHAT_COMPLETIONS_URL =
  "https://api.groq.com/openai/v1/chat/completions";

/** Model evaluated for the Phase 2 migration. */
export const GROQ_MODEL = "openai/gpt-oss-120b";

/**
 * Input ceiling in characters (roughly 4k tokens).
 *
 * The published base Groq limit for this model is 8k tokens per minute and
 * reasoning plus completion tokens count against the same budget, so longer
 * input is rejected with an actionable error instead of being truncated.
 */
export const MAX_INPUT_CHARS = 16000;

/** HTTP statuses worth retrying (rate limits and transient failures). */
const RETRYABLE_STATUS = new Set([408, 409, 429, 500, 502, 503, 504]);

/** Upper bound for a server-supplied retry-after delay. */
const MAX_RETRY_AFTER_MS = 10000;

/** Upper bound for exponential backoff between attempts. */
const MAX_BACKOFF_MS = 4000;

export interface ChatMessage {
  role: "system" | "user";
  content: string;
}

export interface JsonSchemaFormat {
  name: string;
  schema: Record<string, unknown>;
}

export interface GroqChatOptions {
  messages: ChatMessage[];
  /** Strict JSON Schema output, when a typed payload is required. */
  jsonSchema?: JsonSchemaFormat;
  /** Plain JSON mode, used as the fallback when a schema is rejected. */
  jsonObject?: boolean;
  reasoningEffort?: "low" | "medium" | "high";
  temperature?: number;
  maxCompletionTokens?: number;
  /** Timeout for a single HTTP attempt. */
  timeoutMs?: number;
  maxAttempts?: number;
}

export interface GroqChatResult {
  content: string;
  finishReason: string | null;
}

/** Raised when Groq rejects the JSON schema itself. */
export class SchemaRejectedError extends Error {
  /**
   * @param {string} detail Provider message describing the rejection.
   */
  constructor(detail: string) {
    super(detail);
    this.name = "SchemaRejectedError";
  }
}

/** Internal carrier so the retry loop can inspect status and delay. */
class GroqHttpError extends Error {
  readonly httpStatus: number;
  readonly retryable: boolean;
  readonly retryAfterMs: number | null;
  readonly httpsError: HttpsError;

  /**
   * @param {number} httpStatus Status code, 0 for a timeout.
   * @param {boolean} retryable Whether another attempt may succeed.
   * @param {number | null} retryAfterMs Delay requested by Groq, if any.
   * @param {HttpsError} httpsError Error surfaced to the caller.
   */
  constructor(
    httpStatus: number,
    retryable: boolean,
    retryAfterMs: number | null,
    httpsError: HttpsError
  ) {
    super(httpsError.message);
    this.name = "GroqHttpError";
    this.httpStatus = httpStatus;
    this.retryable = retryable;
    this.retryAfterMs = retryAfterMs;
    this.httpsError = httpsError;
  }
}

interface GroqChoice {
  message?: {content?: string; reasoning?: string};
  finish_reason?: string;
}

interface GroqResponse {
  choices?: GroqChoice[];
  usage?: Record<string, unknown>;
}

const sleep = (ms: number): Promise<void> => {
  return new Promise((resolve) => setTimeout(resolve, ms));
};

const backoffMs = (attempt: number): number => {
  const base = Math.min(500 * Math.pow(2, attempt - 1), MAX_BACKOFF_MS);
  return base + Math.floor(Math.random() * 250);
};

const parseRetryAfterMs = (raw: string | null): number | null => {
  if (!raw) return null;
  const seconds = Number(raw);
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  return Math.min(seconds * 1000, MAX_RETRY_AFTER_MS);
};

const extractErrorDetail = (raw: string): string => {
  try {
    const parsed = JSON.parse(raw) as {
      error?: {message?: string; code?: string};
    };
    const message = parsed.error?.message;
    if (typeof message === "string" && message.trim().length > 0) {
      return message.trim().slice(0, 500);
    }
  } catch {
    // Response body was not JSON.
  }
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed.slice(0, 500) : "No details returned.";
};

const looksLikeSchemaRejection = (raw: string): boolean => {
  const lower = raw.toLowerCase();
  return lower.includes("json_validate_failed") ||
    lower.includes("failed to validate json") ||
    lower.includes("schema");
};

const mapHttpError = (status: number, detail: string): HttpsError => {
  if (status === 401 || status === 403) {
    return new HttpsError(
      "failed-precondition",
      "The AI provider rejected the server credentials. The project owner " +
        "needs to set the GROQ_API_KEY secret again."
    );
  }
  if (status === 404) {
    return new HttpsError(
      "failed-precondition",
      "The AI model is not available on this Groq account. " +
        `Provider said: ${detail}`
    );
  }
  if (status === 429) {
    return new HttpsError(
      "resource-exhausted",
      "The AI service rate limit was reached. Please wait a moment and " +
        "try again."
    );
  }
  if (status >= 500) {
    return new HttpsError(
      "unavailable",
      `The AI service is temporarily unavailable (${status}). ` +
        "Please try again in a few moments."
    );
  }
  return new HttpsError(
    "invalid-argument",
    `The AI request was rejected (${status}): ${detail}`
  );
};

/**
 * Logs the per-account rate limit headers.
 *
 * Groq applies limits per organization and can change them, so the real
 * values are read from every response instead of being hard-coded. Compare
 * these log entries with https://console.groq.com/settings/limits.
 *
 * @param {Response} response The Groq HTTP response.
 */
const logRateLimits = (response: Response): void => {
  const requestsLimit = response.headers.get("x-ratelimit-limit-requests");
  if (!requestsLimit) return;
  logger.info("groq.rate_limits", {
    requestsPerDayLimit: requestsLimit,
    requestsRemaining:
      response.headers.get("x-ratelimit-remaining-requests"),
    requestsReset: response.headers.get("x-ratelimit-reset-requests"),
    tokensPerMinuteLimit: response.headers.get("x-ratelimit-limit-tokens"),
    tokensRemaining: response.headers.get("x-ratelimit-remaining-tokens"),
    tokensReset: response.headers.get("x-ratelimit-reset-tokens"),
  });
};

const requestOnce = async (
  apiKey: string,
  body: Record<string, unknown>,
  timeoutMs: number
): Promise<GroqChatResult> => {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(GROQ_CHAT_COMPLETIONS_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    logRateLimits(response);
    const raw = await response.text();

    if (!response.ok) {
      const detail = extractErrorDetail(raw);
      if (response.status === 400 && looksLikeSchemaRejection(raw)) {
        throw new SchemaRejectedError(detail);
      }
      throw new GroqHttpError(
        response.status,
        RETRYABLE_STATUS.has(response.status),
        parseRetryAfterMs(response.headers.get("retry-after")),
        mapHttpError(response.status, detail)
      );
    }

    const parsed = JSON.parse(raw) as GroqResponse;
    const choice = parsed.choices?.[0];
    const content = choice?.message?.content;
    if (typeof content !== "string" || content.trim().length === 0) {
      throw new HttpsError(
        "internal",
        "The AI service returned an empty response. Please try again."
      );
    }
    return {
      content,
      finishReason: choice?.finish_reason ?? null,
    };
  } catch (error: unknown) {
    if (
      error instanceof HttpsError ||
      error instanceof SchemaRejectedError ||
      error instanceof GroqHttpError
    ) {
      throw error;
    }

    const timedOut = error instanceof Error && error.name === "AbortError";
    throw new GroqHttpError(
      timedOut ? 0 : -1,
      true,
      null,
      timedOut ?
        new HttpsError(
          "deadline-exceeded",
          "The AI service did not respond in time. Please try again."
        ) :
        new HttpsError(
          "unavailable",
          "Could not reach the AI service. Please try again."
        )
    );
  } finally {
    clearTimeout(timer);
  }
};

/**
 * Sends a chat completion request to Groq.
 *
 * Retries temporary failures (429/5xx/timeouts) with backoff that honours
 * retry-after, and always fails with a user-facing HttpsError.
 *
 * @param {GroqChatOptions} options Chat completion options.
 * @return {Promise<GroqChatResult>} The assistant message content.
 */
export const callGroqChat = async (
  options: GroqChatOptions
): Promise<GroqChatResult> => {
  let apiKey = "";
  try {
    apiKey = groqApiKey.value().trim();
  } catch (error: unknown) {
    logger.error("groq.secret_unavailable", error);
  }
  if (apiKey.length === 0) {
    throw new HttpsError(
      "failed-precondition",
      "AI is not configured on the server yet. The GROQ_API_KEY secret " +
        "must be set before this feature can work."
    );
  }

  const body: Record<string, unknown> = {
    model: GROQ_MODEL,
    messages: options.messages,
    temperature: options.temperature ?? 0.2,
    max_completion_tokens: options.maxCompletionTokens ?? 1024,
    reasoning_effort: options.reasoningEffort ?? "low",
    stream: false,
  };

  if (options.jsonSchema) {
    body["response_format"] = {
      type: "json_schema",
      json_schema: {
        name: options.jsonSchema.name,
        strict: true,
        schema: options.jsonSchema.schema,
      },
    };
  } else if (options.jsonObject) {
    body["response_format"] = {type: "json_object"};
  }

  const timeoutMs = options.timeoutMs ?? 30000;
  const maxAttempts = Math.max(1, options.maxAttempts ?? 2);

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      return await requestOnce(apiKey, body, timeoutMs);
    } catch (error: unknown) {
      if (!(error instanceof GroqHttpError)) {
        throw error;
      }
      if (!error.retryable || attempt >= maxAttempts) {
        throw error.httpsError;
      }
      const delay = error.retryAfterMs ?? backoffMs(attempt);
      logger.warn("groq.retry", {
        attempt,
        httpStatus: error.httpStatus,
        delayMs: delay,
      });
      await sleep(delay);
    }
  }

  throw new HttpsError(
    "unavailable",
    "The AI service is temporarily unavailable. Please try again."
  );
};
