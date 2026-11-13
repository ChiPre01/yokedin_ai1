import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:yoked_in/ai/config/ai_config.dart';
import 'package:yoked_in/ai/models/meeting_minutes_model.dart';
import 'package:yoked_in/ai/services/meeting_minutes_service.dart';
import 'package:yoked_in/services/network_http_client.dart';

final groqServiceProvider = Provider<GroqService>((ref) {
  final minutesService = ref.watch(meetingMinutesServiceProvider);
  return GroqService(minutesService: minutesService);
});

/// A user-facing AI failure. Widgets can show [message] directly.
class AiServiceException implements Exception {
  final String message;
  final bool isRateLimited;

  const AiServiceException(this.message, {this.isRateLimited = false});

  @override
  String toString() => message;
}

/// Runs the Phase 2 AI features through the existing `yokedin-media-api`
/// Cloudflare Worker.
///
/// Identical method signatures and response normalisation to the former
/// Firebase-callable implementation, so the existing sheets keep working. The
/// Worker verifies the Firebase ID token, checks that the caller belongs to the
/// conversation, then calls Groq. The Groq key lives in a Worker secret and is
/// never sent to this client.
class GroqService {
  GroqService({
    required MeetingMinutesService minutesService,
    http.Client? client,
    String? baseUrl,
  })  : _minutesService = minutesService,
        _client = client ?? workerHttpClient,
        _baseUrl = baseUrl ?? AIConfig.workerBaseUrl;

  final MeetingMinutesService _minutesService;
  final http.Client _client;
  final String _baseUrl;

  /// Generates structured minutes on the server and saves them to Firestore
  /// through the existing [MeetingMinutesService] (unchanged data model).
  ///
  /// Pass either [rawContent] (manual notes, capped at the prompt budget) or
  /// [transcript] (a saved call transcript, which may be far longer: the
  /// Worker condenses it in sections before generating the minutes). Minutes
  /// generated from [transcript] never need the original audio again.
  Future<MeetingMinutesModel> generateAndSaveMeetingMinutes({
    required String conversationId,
    required String conversationType, // 'private' or 'group'
    required String conversationTitle,
    String rawContent = '',
    String? transcript,
    List<String> participants = const [],
    Map<String, String> participantNames = const {},
    int durationSeconds = 0,
    String? meetingId,
  }) async {
    final savedTranscript = transcript?.trim() ?? '';
    final usingTranscript = savedTranscript.isNotEmpty;
    final content = usingTranscript ? savedTranscript : rawContent.trim();

    if (content.isEmpty) {
      throw const AiServiceException(
        'Please enter conversation notes or tap "Use Sample Dialogue".',
      );
    }

    if (usingTranscript) {
      if (content.length > AIConfig.maxCallTranscriptCharacters) {
        throw AiServiceException(
          'This transcript is too long (${content.length} of '
          '${AIConfig.maxCallTranscriptCharacters} characters allowed).',
        );
      }
    } else if (content.length > AIConfig.maxTranscriptCharacters) {
      throw AiServiceException(
        'These notes are too long (${content.length} of '
        '${AIConfig.maxTranscriptCharacters} characters allowed). '
        'Please shorten them and try again.',
      );
    }

    final result = await _invoke(
      AIConfig.generateMinutesPath,
      {
        'conversationId': conversationId,
        'conversationType': conversationType,
        'conversationTitle': conversationTitle,
        if (usingTranscript) 'transcript': content else 'rawContent': content,
        'participants': participants,
        'participantNames': participantNames,
        'durationSeconds': durationSeconds,
      },
      AIConfig.minutesCallTimeout,
    );

    final minuteJson = _asStringMap(result['minute']);
    final summary = _nonEmpty(minuteJson['summary']);
    if (summary == null) {
      throw const AiServiceException(
        'The AI response did not include a summary. Please try again.',
      );
    }

    final minute = MeetingMinutesModel(
      id: '',
      conversationId: conversationId,
      conversationType: conversationType,
      title: _nonEmpty(minuteJson['title']) ?? 'Call with $conversationTitle',
      createdAt: DateTime.now(),
      durationSeconds: durationSeconds,
      participants: participants,
      participantNames: participantNames,
      meetingId: meetingId,
      summary: summary,
      keyDecisions: _stringList(minuteJson['keyDecisions']),
      actionItems: _actionItems(minuteJson['actionItems']),
      rawTranscript: _transcript(minuteJson['transcript']),
    );

    final String docId;
    try {
      docId = await _minutesService.addMeetingMinute(minute);
    } catch (error) {
      debugPrint('Saving meeting minutes failed: $error');
      throw const AiServiceException(
        'The minutes were generated but could not be saved to Firestore. '
        'Please check your connection and try again.',
      );
    }

    return _withId(minute, docId);
  }

  /// Summarizes recent chat messages into a short plain-text summary.
  ///
  /// [conversationId] and [conversationType] identify the conversation so the
  /// Worker can confirm the caller is a participant before calling Groq.
  Future<String> summarizeChatMessages({
    required List<String> messagesFormatted,
    required String conversationTitle,
    required String conversationId,
    required String conversationType,
  }) async {
    if (messagesFormatted.isEmpty) {
      throw const AiServiceException(
        'There are no recent messages to summarize.',
      );
    }
    _requireConversation(conversationId, conversationType);

    final result = await _invoke(
      AIConfig.summarizeChatPath,
      {
        'conversationId': conversationId.trim(),
        'conversationType': conversationType.trim().toLowerCase(),
        'conversationTitle': conversationTitle,
        'messages': messagesFormatted,
      },
      AIConfig.summaryCallTimeout,
    );

    final summary = _nonEmpty(result['summary']);
    if (summary == null) {
      throw const AiServiceException(
        'The AI returned an empty summary. Please try again.',
      );
    }
    return summary;
  }

  /// Generates up to three contextual smart replies.
  ///
  /// Best-effort by design: failures are logged and surface as an empty list
  /// so the chat composer can never break because of AI. Summaries and
  /// meeting minutes deliberately do not do this.
  Future<List<String>> suggestReplies({
    required List<String> recentMessages,
    required String conversationId,
    required String conversationType,
  }) async {
    if (recentMessages.isEmpty) return const [];
    _requireConversation(conversationId, conversationType);
    try {
      final result = await _invoke(
        AIConfig.smartRepliesPath,
        {
          'conversationId': conversationId.trim(),
          'conversationType': conversationType.trim().toLowerCase(),
          'recentMessages': recentMessages.take(10).toList(),
        },
        AIConfig.smartRepliesCallTimeout,
      );
      final replies = _stringList(result['replies']);
      return replies.take(3).toList();
    } on AiServiceException catch (error) {
      debugPrint('Smart reply suggestion failed: ${error.message}');
      return const [];
    }
  }

  void _requireConversation(String conversationId, String conversationType) {
    final id = conversationId.trim();
    final type = conversationType.trim().toLowerCase();
    if (id.isEmpty || (type != 'private' && type != 'group')) {
      throw const AiServiceException(
        'This conversation is not available for AI features right now.',
      );
    }
  }

  Future<Map<String, dynamic>> _invoke(
    String path,
    Map<String, dynamic> payload,
    Duration timeout,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    var token = await user?.getIdToken();
    if (user == null || token == null || token.isEmpty) {
      throw const AiServiceException(
        'Please sign in again to use AI features.',
      );
    }

    var response = await _post(path, payload, token, timeout);

    // A long-lived session can hold a token that expired while the sheet was
    // open. Refresh once before telling the user to sign in again.
    if (response.statusCode == 401) {
      token = await user.getIdToken(true);
      if (token == null || token.isEmpty) {
        throw const AiServiceException(
          'Please sign in again to use AI features.',
        );
      }
      response = await _post(path, payload, token, timeout);
    }

    return _decode(response, path);
  }

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> payload,
    String token,
    Duration timeout,
  ) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      // A local ceiling on top of the Worker's own timeout guarantees the
      // caller's loading state is always released.
      return await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(timeout + AIConfig.callTimeoutGrace);
    } on TimeoutException {
      throw AiServiceException(
        'The AI request took longer than ${timeout.inSeconds} seconds and '
        'was cancelled. Please try again.',
      );
    } catch (error) {
      debugPrint('AI request to $path failed: $error');
      throw const AiServiceException(
        'Could not reach the AI service. Please check your connection and '
        'try again.',
      );
    }
  }

  Map<String, dynamic> _decode(http.Response response, String path) {
    Map<String, dynamic> body = const <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) body = Map<String, dynamic>.from(decoded);
      } catch (_) {
        // Handled by the status checks below.
      }
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (body.isEmpty) {
        throw const AiServiceException(
          'The AI service returned an unexpected response. Please try again.',
        );
      }
      return body;
    }

    final error = body['error'];
    String? code;
    String? serverMessage;
    int? retryAfterSeconds;

    if (error is Map) {
      code = _nonEmpty(error['code']);
      serverMessage = _nonEmpty(error['message']);
      final retryAfter = error['retryAfterSeconds'];
      if (retryAfter is int) retryAfterSeconds = retryAfter;
      if (retryAfter is num) retryAfterSeconds = retryAfter.toInt();
    } else if (error is String) {
      serverMessage = _nonEmpty(error);
    }

    debugPrint(
      'AI request to $path failed (HTTP $status, '
      'code ${code ?? "unknown"}): ${serverMessage ?? "no message"}',
    );

    throw AiServiceException(
      _messageFor(status, code, serverMessage, retryAfterSeconds),
      isRateLimited: status == 429 || code == 'RATE_LIMITED',
    );
  }

  String _messageFor(
    int status,
    String? code,
    String? serverMessage,
    int? retryAfterSeconds,
  ) {
    switch (code) {
      case 'UNAUTHENTICATED':
        return 'Please sign in again to use AI features.';
      case 'FORBIDDEN':
        return serverMessage ??
            'You are not allowed to use AI in this conversation.';
      case 'AI_NOT_CONFIGURED':
        return serverMessage ??
            'AI is not configured on the server yet. '
                'Please contact the project owner.';
      case 'BAD_AI_RESPONSE':
        return serverMessage ??
            'The AI response could not be understood. Please try again.';
    }

    switch (status) {
      case 400:
      case 422:
        return serverMessage ??
            'The AI request was rejected. '
                'Please check the content and try again.';
      case 401:
        return 'Please sign in again to use AI features.';
      case 403:
        return serverMessage ??
            'You are not allowed to use AI in this conversation.';
      case 413:
        return serverMessage ??
            'That content is too long for the AI service. '
                'Please shorten it and try again.';
      case 429:
        final wait =
            (retryAfterSeconds != null && retryAfterSeconds > 0)
                ? retryAfterSeconds
                : 30;
        return serverMessage ??
            'The AI service rate limit was reached. '
                'Please wait $wait seconds and try again.';
      case 502:
        return serverMessage ??
            'The AI service returned an unexpected response. '
                'Please try again.';
      case 503:
        return serverMessage ??
            'The AI service is temporarily unavailable. '
                'Please try again in a few moments.';
      case 504:
        return 'The AI request took too long. Please try again.';
      default:
        return serverMessage ?? 'The AI request failed. Please try again.';
    }
  }

  MeetingMinutesModel _withId(MeetingMinutesModel minute, String docId) {
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
}

Map<String, dynamic> _asStringMap(Object? value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

String? _nonEmpty(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

List<String> _stringList(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

List<ActionItemModel> _actionItems(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map>().map((item) {
    return ActionItemModel(
      task: _nonEmpty(item['task']) ?? 'Unnamed task',
      assignee: _nonEmpty(item['assignee']),
      dueDate: _nonEmpty(item['dueDate']),
      isCompleted: false,
    );
  }).toList();
}

List<TranscriptSegmentModel> _transcript(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map>().map((segment) {
    final text = segment['text'];
    return TranscriptSegmentModel(
      speaker: _nonEmpty(segment['speaker']) ?? 'Participant',
      text: text is String ? text.trim() : '',
      timestamp: _nonEmpty(segment['timestamp']) ?? '00:00',
    );
  }).toList();
}
