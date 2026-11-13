import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:yoked_in/ai/config/ai_config.dart';
import 'package:yoked_in/ai/models/meeting_minutes_model.dart';
import 'package:yoked_in/ai/services/meeting_minutes_service.dart';
import 'package:yoked_in/services/network_http_client.dart';

final geminiServiceProvider = Provider<GeminiService>((ref) {
  final minutesService = ref.watch(meetingMinutesServiceProvider);
  return GeminiService(minutesService: minutesService);
});

class GeminiService {
  final MeetingMinutesService _minutesService;
  final http.Client _client;

  GeminiService({
    required MeetingMinutesService minutesService,
    http.Client? client,
  })  : _minutesService = minutesService,
        _client = client ?? workerHttpClient;

  /// Headers for the Google Gemini Interactions API
  /// Whitelisted by Google CORS gateway (content-type, x-goog-api-key)
  Map<String, String> _buildHeaders() {
    return {
      'Content-Type': 'application/json',
      'x-goog-api-key': AIConfig.geminiApiKey,
    };
  }

  /// Generates structured meeting minutes from raw conversation text or transcript
  /// and persists it to Firestore using the Google Gemini Interactions API.
  Future<MeetingMinutesModel> generateAndSaveMeetingMinutes({
    required String conversationId,
    required String conversationType, // 'private' or 'group'
    required String conversationTitle,
    required String rawContent,
    List<String> participants = const [],
    Map<String, String> participantNames = const {},
    int durationSeconds = 0,
  }) async {
    if (!AIConfig.hasGeminiKey) {
      throw Exception(
        'Gemini API key is not configured. Please add your free Google AI Studio key in AIConfig.geminiApiKey.',
      );
    }

    final systemPrompt = '''
You are an expert executive meeting scribe and conversation intelligence assistant for the Yoked In communication app.
Your task is to analyze the provided conversation/call content between participants and generate structured, professional meeting minutes.

Output strictly valid JSON matching this schema:
{
  "title": "A concise, descriptive title for the meeting (e.g. 'Project Roadmap & Sync with Alice')",
  "summary": "A comprehensive, high-quality executive summary (1-2 paragraphs) covering topics discussed, context, challenges, and overall consensus.",
  "keyDecisions": [
    "Concrete decision 1",
    "Concrete decision 2"
  ],
  "actionItems": [
    {
      "task": "Description of the actionable task",
      "assignee": "Name of assigned person or null if unassigned",
      "dueDate": "Stated deadline or null if unspecified"
    }
  ],
  "transcript": [
    {
      "speaker": "Speaker name",
      "text": "What they said",
      "timestamp": "mm:ss"
    }
  ]
}
''';

    final userContent = '''
Conversation Title: $conversationTitle
Conversation Type: $conversationType
Known Participants: ${participantNames.values.join(', ')}
Call Duration: ${durationSeconds > 0 ? '$durationSeconds seconds' : 'unspecified'}

Conversation Content / Transcript:
$rawContent
''';

    final url = Uri.parse(AIConfig.geminiInteractionsUrl);

    // Using the recommended Interactions API with top-level response_format and gemini-3.8-flash
    final requestBody = {
      'model': AIConfig.geminiModel,
      'system_instruction': systemPrompt,
      'input': userContent,
      'generation_config': {
        // Balanced thinking effort for structured extraction; 'minimal' is unsupported for 3.8
        'thinking_level': 'medium',
      },
      'response_format': {
        'type': 'text',
        'mime_type': 'application/json',
        'schema': {
          'type': 'object',
          'properties': {
            'title': {'type': 'string'},
            'summary': {'type': 'string'},
            'keyDecisions': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'actionItems': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'task': {'type': 'string'},
                  'assignee': {'type': 'string'},
                  'dueDate': {'type': 'string'},
                },
                'required': ['task'],
              },
            },
            'transcript': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'speaker': {'type': 'string'},
                  'text': {'type': 'string'},
                  'timestamp': {'type': 'string'},
                },
                'required': ['speaker', 'text', 'timestamp'],
              },
            },
          },
          'required': [
            'title',
            'summary',
            'keyDecisions',
            'actionItems',
            'transcript',
          ],
        },
      },
    };

    final response = await _client.post(
      url,
      headers: _buildHeaders(),
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      final formattedError = _formatErrorMessage(response);
      debugPrint('Gemini API Error: $formattedError');
      throw Exception(formattedError);
    }

    final responseData = jsonDecode(response.body) as Map<String, dynamic>;
    final rawText = _extractTextFromInteraction(responseData);

    final cleanJsonText = _sanitizeJsonText(rawText);
    final Map<String, dynamic> parsedJson = jsonDecode(cleanJsonText);

    // Parse action items
    final actionItems = (parsedJson['actionItems'] as List<dynamic>?)
            ?.map((e) => ActionItemModel(
                  task: e['task'] as String? ?? 'Unnamed task',
                  assignee: e['assignee'] as String?,
                  dueDate: e['dueDate'] as String?,
                  isCompleted: false,
                ))
            .toList() ??
        [];

    // Parse key decisions
    final keyDecisions = (parsedJson['keyDecisions'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    // Parse transcript segments
    final transcriptSegments = (parsedJson['transcript'] as List<dynamic>?)
            ?.map((e) => TranscriptSegmentModel(
                  speaker: e['speaker'] as String? ?? 'Participant',
                  text: e['text'] as String? ?? '',
                  timestamp: e['timestamp'] as String? ?? '00:00',
                ))
            .toList() ??
        [];

    final minute = MeetingMinutesModel(
      id: '',
      conversationId: conversationId,
      conversationType: conversationType,
      title: parsedJson['title'] as String? ?? 'Call with $conversationTitle',
      createdAt: DateTime.now(),
      durationSeconds: durationSeconds,
      participants: participants,
      participantNames: participantNames,
      summary: parsedJson['summary'] as String? ?? 'No summary generated.',
      keyDecisions: keyDecisions,
      actionItems: actionItems,
      rawTranscript: transcriptSegments,
    );

    // Save to Firestore
    final docId = await _minutesService.addMeetingMinute(minute);

    // Return model with newly assigned ID
    return MeetingMinutesModel(
      id: docId,
      conversationId: minute.conversationId,
      conversationType: minute.conversationType,
      title: minute.title,
      createdAt: minute.createdAt,
      durationSeconds: minute.durationSeconds,
      participants: minute.participants,
      participantNames: minute.participantNames,
      summary: minute.summary,
      keyDecisions: minute.keyDecisions,
      actionItems: minute.actionItems,
      rawTranscript: minute.rawTranscript,
    );
  }

  /// Summarizes recent chat messages into key points and summary using the Interactions API
  Future<String> summarizeChatMessages({
    required List<String> messagesFormatted,
    required String conversationTitle,
  }) async {
    if (!AIConfig.hasGeminiKey) {
      throw Exception(
        'Gemini API key is not configured. Please add your key in AIConfig.geminiApiKey.',
      );
    }

    final systemInstruction =
        'You are a helpful AI assistant in Yoked In. Summarize recent chat messages concisely with key topics, decisions, and any pending items.';

    final userPrompt = '''
Summarize the following recent chat conversation with "$conversationTitle":

Messages:
${messagesFormatted.join('\n')}
''';

    final url = Uri.parse(AIConfig.geminiInteractionsUrl);

    final requestBody = {
      'model': AIConfig.geminiModel,
      'system_instruction': systemInstruction,
      'input': userPrompt,
      'generation_config': {
        'thinking_level': 'low', // Fast latency for chat summaries
      },
    };

    final response = await _client.post(
      url,
      headers: _buildHeaders(),
      body: jsonEncode(requestBody),
    );

    if (response.statusCode != 200) {
      final formattedError = _formatErrorMessage(response);
      debugPrint('Gemini API Error: $formattedError');
      throw Exception(formattedError);
    }

    final responseData = jsonDecode(response.body) as Map<String, dynamic>;
    return _extractTextFromInteraction(responseData);
  }

  /// Generates 3 contextual smart reply suggestions using the Interactions API
  Future<List<String>> suggestReplies({
    required List<String> recentMessages,
  }) async {
    if (!AIConfig.hasGeminiKey || recentMessages.isEmpty) {
      return [];
    }

    final systemInstruction =
        'Suggest 3 short, natural, polite reply options for the user to quickly send based on recent messages.';

    final userPrompt = '''
Given these recent chat messages:
${recentMessages.take(10).join('\n')}

Provide 3 quick reply options formatted as a JSON array of strings.
''';

    final url = Uri.parse(AIConfig.geminiInteractionsUrl);

    final requestBody = {
      'model': AIConfig.geminiModel,
      'system_instruction': systemInstruction,
      'input': userPrompt,
      'generation_config': {
        'thinking_level': 'low',
      },
      'response_format': {
        'type': 'text',
        'mime_type': 'application/json',
        'schema': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
    };

    try {
      final response = await _client.post(
        url,
        headers: _buildHeaders(),
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body) as Map<String, dynamic>;
        final rawText = _extractTextFromInteraction(responseData);
        final cleanJsonText = _sanitizeJsonText(rawText);
        final List<dynamic> list = jsonDecode(cleanJsonText);
        return list.map((e) => e.toString()).toList();
      } else {
        debugPrint(
            'Smart replies failed with status: ${response.statusCode} - ${_formatErrorMessage(response)}');
      }
    } catch (e) {
      debugPrint('Smart reply suggestion error: $e');
    }

    return [];
  }

  /// Extracts text output across all Interactions API response variations:
  /// 1. `output_text` field
  /// 2. `steps` array with `model_output` type
  /// 3. `outputs` array (legacy interactions)
  /// 4. `candidates` array (fallback generateContent)
  String _extractTextFromInteraction(Map<String, dynamic> data) {
    // 1. Direct output_text convenience property
    if (data['output_text'] is String &&
        (data['output_text'] as String).trim().isNotEmpty) {
      return data['output_text'] as String;
    }

    // 2. Standard Interactions API steps array
    final steps = data['steps'] as List<dynamic>?;
    if (steps != null && steps.isNotEmpty) {
      for (final step in steps.reversed) {
        if (step is Map) {
          final stepType = step['type']?.toString();
          if (stepType == 'model_output' || stepType == null) {
            final contentList = step['content'] as List<dynamic>?;
            if (contentList != null && contentList.isNotEmpty) {
              for (final content in contentList) {
                if (content is Map && content['text'] is String) {
                  return content['text'] as String;
                }
              }
            }
          }
        }
      }
    }

    // 3. Legacy outputs array
    final outputs = data['outputs'] as List<dynamic>?;
    if (outputs != null && outputs.isNotEmpty) {
      for (final output in outputs.reversed) {
        if (output is Map && output['text'] is String) {
          return output['text'] as String;
        }
      }
    }

    // 4. Fallback candidates array
    final candidates = data['candidates'] as List<dynamic>?;
    if (candidates != null && candidates.isNotEmpty) {
      final parts = candidates.first['content']?['parts'] as List<dynamic>?;
      if (parts != null && parts.isNotEmpty && parts.first['text'] is String) {
        return parts.first['text'] as String;
      }
    }

    throw Exception('No text content found in model response.');
  }

  /// Cleans markdown fences (e.g. ```json ... ```) from JSON responses
  String _sanitizeJsonText(String text) {
    var trimmed = text.trim();
    if (trimmed.startsWith('```json')) {
      trimmed = trimmed.substring(7);
    } else if (trimmed.startsWith('```')) {
      trimmed = trimmed.substring(3);
    }
    if (trimmed.endsWith('```')) {
      trimmed = trimmed.substring(0, trimmed.length - 3);
    }
    return trimmed.trim();
  }

  /// Formats HTTP errors into actionable user-facing messages
  String _formatErrorMessage(http.Response response) {
    final code = response.statusCode;
    String apiMessage = response.body;

    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['error'] is Map) {
        final err = decoded['error'] as Map<String, dynamic>;
        apiMessage = err['message']?.toString() ?? response.body;
      }
    } catch (_) {
      // Body not JSON
    }

    if (code == 401 || code == 403) {
      return 'Invalid or unauthorized Gemini API key ($code). Please check your key in settings.';
    } else if (code == 404) {
      return 'Model or endpoint not found ($code): $apiMessage';
    } else if (code == 429) {
      return 'Rate limit exceeded ($code). The free quota limit has been reached; please retry shortly.';
    } else if (code >= 500) {
      return 'Google AI service temporarily unavailable ($code). Please try again in a few moments.';
    }

    return 'Gemini API Error ($code): $apiMessage';
  }
}
