import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:yoked_in/ai/config/ai_config.dart';
import 'package:yoked_in/calls/call_recording_models.dart';
import 'package:yoked_in/services/network_http_client.dart';

/// Result of transcribing one uploaded recording part.
class ChunkTranscription {
  const ChunkTranscription({
    required this.text,
    required this.segments,
    required this.durationSeconds,
  });

  final String text;
  final List<CallTranscriptSegment> segments;
  final double durationSeconds;
}

/// Client for the Worker's speech-to-text route.
///
/// The audio never leaves the Worker's own R2 bucket for the client: the
/// Worker reads the object it already stores and forwards it to the provider,
/// so the Groq key stays in a Worker secret.
class CallTranscriptionApi {
  CallTranscriptionApi({http.Client? client, String? baseUrl})
      : _client = client ?? workerHttpClient,
        _baseUrl = baseUrl ?? AIConfig.workerBaseUrl;

  final http.Client _client;
  final String _baseUrl;

  Future<ChunkTranscription> transcribeChunk({
    required String mediaKey,
    required int chunkIndex,
    required String conversationId,
    required String conversationType,
    String? language,
  }) async {
    final payload = <String, dynamic>{
      'mediaKey': mediaKey,
      'chunkIndex': chunkIndex,
      'conversationId': conversationId,
      'conversationType': conversationType,
      if (language != null && language.trim().isNotEmpty)
        'language': language.trim(),
    };

    final body = await _invoke(AIConfig.transcribePath, payload);

    final text = (body['text'] ?? '').toString().trim();

    final rawSegments = body['segments'];
    final segments = rawSegments is List
        ? rawSegments
            .map(CallTranscriptSegment.fromMap)
            .whereType<CallTranscriptSegment>()
            .toList()
        : <CallTranscriptSegment>[];

    if (text.isEmpty && segments.isEmpty) {
      throw const CallTranscriptionException(
        'No speech was recognised in this recording part.',
      );
    }

    final reportedDuration = body['durationSeconds'];
    final durationSeconds = reportedDuration is num
        ? reportedDuration.toDouble()
        : double.tryParse(reportedDuration?.toString() ?? '') ?? 0;

    return ChunkTranscription(
      text: text.isNotEmpty
          ? text
          : segments.map((segment) => segment.text).join(' ').trim(),
      segments: segments,
      durationSeconds: durationSeconds,
    );
  }

  Future<Map<String, dynamic>> _invoke(
    String path,
    Map<String, dynamic> payload,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    var token = await user?.getIdToken();
    if (user == null || token == null || token.isEmpty) {
      throw const CallTranscriptionException(
        'Please sign in again to transcribe this recording.',
      );
    }

    var response = await _post(path, payload, token);

    // A long call can outlive the token that was loaded when it started.
    if (response.statusCode == 401) {
      token = await user.getIdToken(true);
      if (token == null || token.isEmpty) {
        throw const CallTranscriptionException(
          'Please sign in again to transcribe this recording.',
        );
      }
      response = await _post(path, payload, token);
    }

    Map<String, dynamic> body = const <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) body = Map<String, dynamic>.from(decoded);
      } catch (_) {
        // Handled by the status checks below.
      }
    }

    if (response.statusCode == 200) return body;

    final error = body['error'];
    final message = error is Map
        ? (error['message'] ?? '').toString()
        : (body['error'] ?? '').toString();

    throw CallTranscriptionException(
      message.isNotEmpty
          ? message
          : 'The recording could not be transcribed '
              '(HTTP ${response.statusCode}).',
    );
  }

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> payload,
    String token,
  ) async {
    final uri = Uri.parse('$_baseUrl$path');
    try {
      return await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(AIConfig.transcriptionCallTimeout);
    } on TimeoutException {
      throw const CallTranscriptionException(
        'The transcription took too long and was cancelled. '
        'The recording is still saved, so you can retry.',
      );
    } catch (error) {
      debugPrint('Transcription request to $path failed: $error');
      throw const CallTranscriptionException(
        'Could not reach the transcription service. '
        'The recording is still saved, so you can retry.',
      );
    }
  }
}

class CallTranscriptionException implements Exception {
  const CallTranscriptionException(this.message);

  final String message;

  @override
  String toString() => message;
}
