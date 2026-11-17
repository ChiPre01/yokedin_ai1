import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:yoked_in/ai/config/ai_config.dart';
import 'package:yoked_in/services/network_http_client.dart';

final characterAiServiceProvider = Provider<CharacterAiService>((ref) {
  return CharacterAiService();
});

/// A user-facing character-generation failure. Widgets show [message].
class CharacterAiException implements Exception {
  final String message;
  final bool isNotConfigured;

  const CharacterAiException(this.message, {this.isNotConfigured = false});

  @override
  String toString() => message;
}

/// Calls the Worker's character endpoints.
///
/// Same contract as [GroqService]: the Worker verifies the Firebase ID token
/// and holds the provider keys, so nothing secret exists in this app.
class CharacterAiService {
  CharacterAiService({http.Client? client, String? baseUrl})
      : _client = client ?? workerHttpClient,
        _baseUrl = baseUrl ?? AIConfig.workerBaseUrl;

  final http.Client _client;
  final String _baseUrl;

  /// Turns a description (and optional category/role hints) into a structured
  /// character. When [imageKey] is supplied the Worker lets the AI study that
  /// uploaded picture first; otherwise it works from the text alone.
  Future<Map<String, dynamic>> draftCharacter({
    required String description,
    String? category,
    String? role,
    String? imageKey,
  }) {
    return _invoke(
      AIConfig.characterDraftPath,
      {
        'description': description,
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
        if (role != null && role.trim().isNotEmpty) 'role': role.trim(),
        if (imageKey != null && imageKey.trim().isNotEmpty)
          'imageKey': imageKey.trim(),
      },
      AIConfig.characterDraftTimeout,
    );
  }

  /// Generates the portrait for an existing (or just-created) character and
  /// stores it in R2 under the caller's own prefix.
  ///
  /// [referenceKeys] are uploaded pictures of the same character; when present
  /// the Worker uses the reference-aware model so the face is kept instead of
  /// invented.
  Future<Map<String, dynamic>> generatePortrait({
    required String characterId,
    required String prompt,
    List<String> referenceKeys = const [],
  }) {
    return _invoke(
      AIConfig.characterImagePath,
      {
        'characterId': characterId,
        'prompt': prompt,
        if (referenceKeys.isNotEmpty)
          'referenceKeys': referenceKeys.take(3).toList(),
      },
      AIConfig.characterImageTimeout,
    );
  }

  Future<Map<String, dynamic>> _invoke(
    String path,
    Map<String, dynamic> payload,
    Duration timeout,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const CharacterAiException(
        'Please sign in again to create characters.',
      );
    }

    var token = await user.getIdToken();
    if (token == null || token.isEmpty) {
      throw const CharacterAiException(
        'Please sign in again to create characters.',
      );
    }

    var response = await _post(path, payload, token, timeout);

    // A session that sat idle can hold an expired token; refresh once before
    // asking the user to sign in again.
    if (response.statusCode == 401) {
      token = await user.getIdToken(true);
      if (token == null || token.isEmpty) {
        throw const CharacterAiException(
          'Please sign in again to create characters.',
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
      throw CharacterAiException(
        'The character request took longer than ${timeout.inSeconds} seconds '
        'and was cancelled. Please try again.',
      );
    } catch (error) {
      debugPrint('Character request to $path failed: $error');
      throw const CharacterAiException(
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
        throw const CharacterAiException(
          'The AI service returned an unexpected response. Please try again.',
        );
      }
      return body;
    }

    final error = body['error'];
    String? code;
    String? serverMessage;

    if (error is Map) {
      code = (error['code'] ?? '').toString();
      serverMessage = (error['message'] ?? '').toString().trim();
    } else if (error is String) {
      serverMessage = error.trim();
    }

    debugPrint(
      'Character request to $path failed (HTTP $status, '
      'code ${code ?? "unknown"}): ${serverMessage ?? "no message"}',
    );

    final message = serverMessage == null || serverMessage.isEmpty
        ? _defaultMessage(status)
        : serverMessage;

    throw CharacterAiException(
      message,
      isNotConfigured: code == 'AI_NOT_CONFIGURED',
    );
  }

  String _defaultMessage(int status) {
    switch (status) {
      case 400:
      case 422:
        return 'The character description was rejected. Please change it and '
            'try again.';
      case 401:
        return 'Please sign in again to create characters.';
      case 429:
        return 'That is a lot of character requests in a short time. '
            'Please wait a moment and try again.';
      case 503:
        return 'Character generation is not available right now. '
            'Please try again later.';
      default:
        return 'The character request failed. Please try again.';
    }
  }
}
