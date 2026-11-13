/// Configuration for AI services.
///
/// Phase 2 routes AI work through the existing `yokedin-media-api` Cloudflare
/// Worker, which calls Groq and keeps the provider key in a Worker secret. The
/// app never holds a provider key. The Gemini settings at the bottom are kept
/// until Groq has been verified on Chrome and Android, per the migration plan.
class AIConfig {
  AIConfig._();

  // ---------------------------------------------------------------------
  // Groq (via the yokedin-media-api Cloudflare Worker)
  // ---------------------------------------------------------------------

  /// Base URL of the Worker that serves media and the AI endpoints.
  static const String workerBaseUrl =
      "https://yokedin-media-api.ogaizi70.workers.dev";

  /// AI endpoint paths, appended to [workerBaseUrl].
  static const String summarizeChatPath = "/ai/summarize-chat";
  static const String generateMinutesPath = "/ai/generate-meeting-minutes";
  static const String smartRepliesPath = "/ai/smart-replies";
  static const String transcribePath = "/ai/transcribe";

  /// Provider label used in AI copy.
  static const String aiProviderName = "Groq AI";

  /// Model served by the Worker. Display only: the API key lives in Worker
  /// secrets and never reaches the client.
  static const String groqModel = "openai/gpt-oss-120b";

  /// Input ceiling enforced by the minutes endpoint.
  /// Must match MAX_INPUT_CHARS in cloudflare/worker/src/index.js.
  static const int maxTranscriptCharacters = 16000;

  /// A saved call transcript may be much longer than the manual-notes
  /// ceiling; the Worker condenses it in sections before the minutes prompt.
  /// Must match MAX_CALL_TRANSCRIPT_CHARS in cloudflare/worker/src/index.js.
  static const int maxCallTranscriptCharacters = 120000;

  /// Client-side call ceilings. The Worker applies its own, shorter provider
  /// timeouts, so a loading indicator can never spin indefinitely.
  static const Duration minutesCallTimeout = Duration(seconds: 100);
  static const Duration summaryCallTimeout = Duration(seconds: 60);
  static const Duration smartRepliesCallTimeout = Duration(seconds: 40);

  /// One recording part is transcribed server-side with its own provider
  /// timeout; this ceiling only bounds the client wait.
  static const Duration transcriptionCallTimeout = Duration(seconds: 120);

  /// Extra grace added on top of a call timeout before the client gives up.
  static const Duration callTimeoutGrace = Duration(seconds: 5);

  // ---------------------------------------------------------------------
  // Google Gemini (legacy, kept until Groq is verified)
  // ---------------------------------------------------------------------

  /// Google Gemini API Key.
  /// Set via the UI or runtime configuration. Do not commit hardcoded keys.
  static String geminiApiKey = "";

  /// The legacy Gemini model, still used by gemini_service.dart.
  static String geminiModel = "gemini-3.8-flash";

  /// Base URL for the Google Gemini Interactions API (v1beta)
  static const String geminiInteractionsUrl =
      "https://generativelanguage.googleapis.com/v1beta/interactions";

  /// Check whether an API key has been configured
  static bool get hasGeminiKey =>
      geminiApiKey.trim().isNotEmpty && !geminiApiKey.contains("YOUR_");
}
