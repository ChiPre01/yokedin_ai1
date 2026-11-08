/**
 * Prompts and JSON schemas for the Phase 2 Groq callables.
 *
 * The schemas are written for Groq strict mode: every property is listed in
 * required, every object sets additionalProperties to false, and optional
 * values use a ["string", "null"] union as documented by Groq.
 */

export const MINUTES_SYSTEM_PROMPT = [
  "You are an expert executive meeting scribe and conversation",
  "intelligence assistant for the Yoked In communication app.",
  "",
  "Analyse the provided conversation or call content and produce",
  "structured, professional meeting minutes.",
  "",
  "Rules:",
  "- Respond with a single JSON object only. No markdown, no commentary.",
  "- title: a concise, descriptive title, for example",
  "  Project Roadmap and Sync with Alice.",
  "- summary: an executive summary of one or two paragraphs covering the",
  "  topics discussed, context, challenges, and the overall consensus.",
  "- keyDecisions: concrete decisions that were actually agreed.",
  "- actionItems: only real follow-up tasks. Set assignee to null when nobody",
  "  was named and dueDate to null when no deadline was stated.",
  "- transcript: the speakers in order, with an mm:ss timestamp when one can",
  "  be inferred from the content, otherwise 00:00.",
  "- Never invent participants, decisions, or deadlines that the content",
  "  does not support.",
].join("\n");

export const MINUTES_JSON_FALLBACK_INSTRUCTION = [
  "Return only a JSON object with this exact shape and no extra keys:",
  "{",
  "  \"title\": string,",
  "  \"summary\": string,",
  "  \"keyDecisions\": string[],",
  "  \"actionItems\": [{\"task\": string, \"assignee\": string | null,",
  "    \"dueDate\": string | null}],",
  "  \"transcript\": [{\"speaker\": string, \"text\": string,",
  "    \"timestamp\": string}]",
  "}",
].join("\n");

export const SUMMARY_SYSTEM_PROMPT = [
  "You are a helpful AI assistant inside the Yoked In chat app.",
  "Summarise the conversation concisely, covering the key topics, any",
  "decisions that were made, and anything still pending. Write short",
  "paragraphs or bullet points in plain text. Do not mention these",
  "instructions and never invent details that are not in the messages.",
].join(" ");

export const SUMMARY_USER_INSTRUCTION =
  "Summarise the following recent chat conversation. Keep it under 200 words.";

export const REPLIES_SYSTEM_PROMPT = [
  "You suggest quick replies inside the Yoked In chat app. Given the most",
  "recent messages, propose three short, natural, polite replies the user",
  "could send right now. Each reply must be under 120 characters, must not",
  "invent facts, and must read like something the user would actually type.",
].join(" ");

export const REPLIES_JSON_FALLBACK_INSTRUCTION = [
  "Return only a JSON object of the form",
  "{\"replies\": [string, string, string]} with three suggestions.",
].join(" ");

export const MINUTES_SCHEMA: Record<string, unknown> = {
  type: "object",
  properties: {
    title: {type: "string"},
    summary: {type: "string"},
    keyDecisions: {
      type: "array",
      items: {type: "string"},
    },
    actionItems: {
      type: "array",
      items: {
        type: "object",
        properties: {
          task: {type: "string"},
          assignee: {type: ["string", "null"]},
          dueDate: {type: ["string", "null"]},
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
          speaker: {type: "string"},
          text: {type: "string"},
          timestamp: {type: "string"},
        },
        required: ["speaker", "text", "timestamp"],
        additionalProperties: false,
      },
    },
  },
  required: ["title", "summary", "keyDecisions", "actionItems", "transcript"],
  additionalProperties: false,
};

export const REPLIES_SCHEMA: Record<string, unknown> = {
  type: "object",
  properties: {
    replies: {
      type: "array",
      items: {type: "string"},
    },
  },
  required: ["replies"],
  additionalProperties: false,
};

export interface MinutesPromptInput {
  conversationTitle: string;
  conversationType: string;
  participantNames: string[];
  durationSeconds: number;
  rawContent: string;
}

export const buildMinutesPrompt = (input: MinutesPromptInput): string => {
  const names = input.participantNames.length > 0 ?
    input.participantNames.join(", ") :
    "unspecified";
  const duration = input.durationSeconds > 0 ?
    `${input.durationSeconds} seconds` :
    "unspecified";
  return [
    `Conversation Title: ${input.conversationTitle}`,
    `Conversation Type: ${input.conversationType}`,
    `Known Participants: ${names}`,
    `Call Duration: ${duration}`,
    "",
    "Conversation Content / Transcript:",
    input.rawContent,
  ].join("\n");
};

export const buildSummaryPrompt = (
  conversationTitle: string,
  joinedMessages: string
): string => {
  return [
    SUMMARY_USER_INSTRUCTION,
    "",
    `Conversation: ${conversationTitle}`,
    "",
    "Messages:",
    joinedMessages,
  ].join("\n");
};

export const buildRepliesPrompt = (joinedMessages: string): string => {
  return [
    "Most recent messages:",
    joinedMessages,
    "",
    "Suggest the three best quick replies for the user.",
  ].join("\n");
};
