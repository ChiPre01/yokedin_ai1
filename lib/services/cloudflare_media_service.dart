
import 'dart:collection';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:yoked_in/services/network_http_client.dart';

/// Handles authenticated media uploads, downloads and deletions
/// through the YokedIn Cloudflare Worker.
class CloudflareMediaService {
  CloudflareMediaService._();

  static final CloudflareMediaService instance =
      CloudflareMediaService._();

  static const String baseUrl =
      'https://yokedin-media-api.ogaizi70.workers.dev';

  /// Retained for compatibility with existing code.
  static const int maxFileSize = 25 * 1024 * 1024;

  /// Mirrors SIZE_LIMITS in the Worker. Call recordings upload as `audio` and
  /// are capped at 25 MB per part, which is also the speech-to-text ceiling.
  static const Map<String, int> _sizeLimits = {
    'image': 25 * 1024 * 1024,
    'video': 25 * 1024 * 1024,
    'voice': 25 * 1024 * 1024,
    'audio': 25 * 1024 * 1024,
    'document': 10 * 1024 * 1024,
  };

  static const Duration requestTimeout = Duration(seconds: 60);

  /// Shown when the device cannot open a connection to the Worker at all,
  /// which is a network problem rather than a rejected upload.
  static const String _unreachableMessage =
      'Cannot reach the media server. Check your internet connection '
      'and try again.';

  // Keep recently downloaded images in memory so navigation between pages
  // does not trigger another authenticated download and progress indicator.
  // The cache is bounded to avoid retaining an unlimited amount of image data.
  static const int _maxImageCacheBytes = 40 * 1024 * 1024;
  static final LinkedHashMap<String, Uint8List> _imageCache =
      LinkedHashMap<String, Uint8List>();
  static final Map<String, Future<Uint8List>> _downloadsInProgress = {};
  static int _cachedImageBytes = 0;

  String _cacheKey(String mediaUrl) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'signed-out';
    return '$uid|$mediaUrl';
  }

  static void _rememberImage(String key, Uint8List bytes) {
    if (bytes.isEmpty || bytes.lengthInBytes > _maxImageCacheBytes) return;

    final previous = _imageCache.remove(key);
    if (previous != null) _cachedImageBytes -= previous.lengthInBytes;

    while (_cachedImageBytes + bytes.lengthInBytes > _maxImageCacheBytes &&
        _imageCache.isNotEmpty) {
      final oldestKey = _imageCache.keys.first;
      final oldestBytes = _imageCache.remove(oldestKey)!;
      _cachedImageBytes -= oldestBytes.lengthInBytes;
    }

    _imageCache[key] = bytes;
    _cachedImageBytes += bytes.lengthInBytes;
  }

  /// Clear cached image bytes when the signed-in account changes.
  static void clearImageCache() {
    _imageCache.clear();
    _downloadsInProgress.clear();
    _cachedImageBytes = 0;
  }

  /// Returns cached image bytes synchronously, updating their LRU position.
  Uint8List? getCachedImage(String mediaUrl) {
    final key = _cacheKey(mediaUrl);
    final bytes = _imageCache.remove(key);
    if (bytes == null) return null;
    _imageCache[key] = bytes;
    return bytes;
  }

  Future<String> _getAuthToken({bool forceRefresh = false}) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw CloudflareMediaException(
        'You must sign in before accessing media.',
      );
    }

    final token = await user.getIdToken(forceRefresh);

    if (token == null || token.isEmpty) {
      throw CloudflareMediaException(
        'Unable to obtain your authentication token. '
        'Please sign in again.',
      );
    }

    return token;
  }

  String _getContentType(String fileName) {
    final name = fileName.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    final extension =
        dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';

    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'mp4':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
        return 'audio/mp4';
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'aac':
        return 'audio/aac';
      case '3gp':
        return 'audio/3gpp';
      case 'pdf':
        return 'application/pdf';
      case 'txt':
        return 'text/plain';
      case 'rtf':
        return 'application/rtf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      default:
        throw CloudflareMediaException(
          'Unsupported file extension: ${extension.isEmpty ? "(none)" : ".$extension"}.',
        );
    }
  }

  String _inferCategory(String contentType) {
    if (contentType.startsWith('image/')) return 'image';
    if (contentType.startsWith('video/')) return 'video';
    if (contentType.startsWith('audio/')) return 'audio';

    if (contentType == 'application/pdf' ||
        contentType == 'text/plain' ||
        contentType == 'application/rtf' ||
        contentType == 'application/msword' ||
        contentType.startsWith(
          'application/vnd.openxmlformats-officedocument.',
        ) ||
        contentType == 'application/vnd.ms-excel' ||
        contentType == 'application/vnd.ms-powerpoint') {
      return 'document';
    }

    throw CloudflareMediaException(
      'This file type is not supported.',
    );
  }

  /// Uploads media to Cloudflare R2.
  ///
  /// Profile uploads can continue using uploadFile(file) as before.
  ///
  /// Private chat:
  /// uploadFile(file, purpose: 'chat', chatId: chatId)
  ///
  /// Group chat:
  /// uploadFile(file, purpose: 'group', groupId: groupId)
  ///
  /// Character reference photo:
  /// uploadFile(file, purpose: 'character', characterId: characterId)
  ///
  Future<Map<String, dynamic>> uploadFile(
    XFile file, {
    String purpose = 'profile',
    String? chatId,
    String? groupId,
    String? characterId,
    String? category,
    String? contentTypeOverride,
  }) async {
    if (!['profile', 'chat', 'group', 'character'].contains(purpose)) {
      throw CloudflareMediaException('Invalid media purpose.');
    }

    if (purpose == 'character' &&
        (characterId == null || characterId.trim().isEmpty)) {
      throw CloudflareMediaException(
        'A character ID is required for character photos.',
      );
    }

    if (purpose != 'character' && characterId != null) {
      throw CloudflareMediaException(
        'A character ID can only be used for character photos.',
      );
    }

    if (purpose == 'chat' &&
        (chatId == null || chatId.trim().isEmpty)) {
      throw CloudflareMediaException(
        'A chat ID is required for private-chat media.',
      );
    }

    if (purpose == 'group' &&
        (groupId == null || groupId.trim().isEmpty)) {
      throw CloudflareMediaException(
        'A group ID is required for group media.',
      );
    }

    if (purpose != 'chat' && chatId != null) {
      throw CloudflareMediaException(
        'A chat ID can only be used for private-chat media.',
      );
    }

    if (purpose != 'group' && groupId != null) {
      throw CloudflareMediaException(
        'A group ID can only be used for group media.',
      );
    }

    // A call recording part is an audio-only MP4 file whose name ends in
    // `.mp4`, so the MIME type must be supplied explicitly: deriving it from
    // the extension would classify it as video.
    final contentType = contentTypeOverride ?? _getContentType(file.name);
    final inferredCategory = _inferCategory(contentType);
    final mediaCategory = category ?? inferredCategory;

    if (!_sizeLimits.containsKey(mediaCategory)) {
      throw CloudflareMediaException('Invalid media category.');
    }

    if (mediaCategory != inferredCategory) {
      throw CloudflareMediaException(
        'The selected media category does not match the file type.',
      );
    }

    if (purpose == 'profile' && mediaCategory != 'image') {
      throw CloudflareMediaException(
        'Profile uploads must be images.',
      );
    }

    if (purpose == 'character' && mediaCategory != 'image') {
      throw CloudflareMediaException(
        'Character photos must be images.',
      );
    }

    final bytes = await file.readAsBytes();

    if (bytes.isEmpty) {
      throw CloudflareMediaException(
        'The selected file is empty.',
      );
    }

    final sizeLimit = _sizeLimits[mediaCategory]!;

    if (bytes.length > sizeLimit) {
      final limitMb = sizeLimit ~/ (1024 * 1024);
      throw CloudflareMediaException(
        'This $mediaCategory file exceeds the $limitMb MB limit.',
      );
    }

    final token = await _getAuthToken();
    final uri = Uri.parse('$baseUrl/upload');
    final request = http.Request('POST', uri);

    request.headers.addAll({
      'Authorization': 'Bearer $token',
      'Content-Type': contentType,
      'X-File-Name': Uri.encodeComponent(file.name),
      'X-Media-Purpose': purpose,
      'X-Media-Category': mediaCategory,
      if (chatId != null) 'X-Chat-Id': chatId,
      if (groupId != null) 'X-Group-Id': groupId,
      if (characterId != null) 'X-Character-Id': characterId,
    });

    request.bodyBytes = bytes;

    final http.StreamedResponse streamedResponse;

    try {
      streamedResponse =
          await workerHttpClient.send(request).timeout(requestTimeout);
    } on http.ClientException catch (error) {
      debugPrint('[MEDIA] Upload connection failed: $error');
      throw CloudflareMediaException(_unreachableMessage);
    }

    final response = await http.Response.fromStream(
      streamedResponse,
    ).timeout(requestTimeout);

    final Map<String, dynamic> data;

    try {
      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Unexpected response format.');
      }

      data = decoded;
    } catch (_) {
      throw CloudflareMediaException(
        'The media server returned an invalid response '
        '(HTTP ${response.statusCode}).',
      );
    }

    if (response.statusCode != 201 || data['success'] != true) {
      throw CloudflareMediaException(
        data['error']?.toString() ??
            'Upload failed (HTTP ${response.statusCode}).',
      );
    }

    if (data['url'] is! String || data['key'] is! String) {
      throw CloudflareMediaException(
        'The server response is missing the media URL or key.',
      );
    }

    return data;
  }

  /// Downloads media through the authenticated Worker.
  /// Successful image downloads are cached and shared by concurrent requests.
  Future<Uint8List> downloadMedia(String mediaUrl) async {
    final uri = Uri.parse(mediaUrl);
    final baseUri = Uri.parse(baseUrl);

    if (uri.scheme != 'https' ||
        uri.host != baseUri.host ||
        uri.port != baseUri.port) {
      throw CloudflareMediaException(
        'The media URL is not from the configured media server.',
      );
    }

    final key = _cacheKey(mediaUrl);
    final cached = _imageCache.remove(key);
    if (cached != null) {
      _imageCache[key] = cached;
      return cached;
    }

    final pending = _downloadsInProgress[key];
    if (pending != null) return pending;

    final future = _downloadUncached(uri, key);
    _downloadsInProgress[key] = future;
    try {
      return await future;
    } finally {
      _downloadsInProgress.remove(key);
    }
  }

  Future<Uint8List> _downloadUncached(Uri uri, String cacheKey) async {
    final token = await _getAuthToken();
    http.Response? response;

    try {
      response = await workerHttpClient.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(requestTimeout);
    } catch (error) {
      // A pooled connection can be dropped by the edge while the app sits
      // idle. Retrying once on a brand-new connection, with a refreshed
      // token, recovers instead of leaving a broken picture on screen.
      debugPrint('[MEDIA] Download attempt failed: $error');
      response = await _retryDownload(uri);
    }

    if (response == null) {
      throw CloudflareMediaException(_unreachableMessage);
    }

    if (response.statusCode != 200) {
      debugPrint(
        '[MEDIA] Download failed (HTTP ${response.statusCode}) for $uri',
      );
    }

    if (response.statusCode == 410) {
      throw CloudflareMediaException('This media has expired.');
    }

    if (response.statusCode != 200) {
      throw CloudflareMediaException(
        'Unable to download media (HTTP ${response.statusCode}).',
      );
    }

    final bytes = response.bodyBytes;
    // The app now only downloads chat media pictures through this path.
    _rememberImage(cacheKey, bytes);
    return bytes;
  }

  /// Second chance for a download that failed on the shared client.
  Future<http.Response?> _retryDownload(Uri uri) async {
    try {
      final token = await _getAuthToken(forceRefresh: true);
      final client = http.Client();

      try {
        return await client
            .get(uri, headers: {'Authorization': 'Bearer $token'})
            .timeout(requestTimeout);
      } finally {
        client.close();
      }
    } catch (error) {
      debugPrint('[MEDIA] Download retry failed: $error');
      return null;
    }
  }

  /// Deletes a media object owned by the signed-in user.
  Future<void> deleteMedia(String mediaKey) async {
    final token = await _getAuthToken();
    final key = mediaKey.trim();

    if (key.isEmpty ||
        key.startsWith('/') ||
        key.contains('..') ||
        key.contains('\\')) {
      throw CloudflareMediaException(
        'Invalid media storage key.',
      );
    }

    final uri = Uri.parse('$baseUrl/media/$key');

    final http.Response response;

    try {
      response = await workerHttpClient.delete(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(requestTimeout);
    } on http.ClientException catch (error) {
      debugPrint('[MEDIA] Delete connection failed: $error');
      throw CloudflareMediaException(_unreachableMessage);
    }

    if (response.statusCode != 200) {
      String message =
          'Media deletion failed (HTTP ${response.statusCode}).';

      try {
        final data = jsonDecode(response.body);
        if (data is Map && data['error'] != null) {
          message = data['error'].toString();
        }
      } catch (_) {
        // Keep the default error message.
      }

      throw CloudflareMediaException(message);
    }
  }
}

class CloudflareMediaException implements Exception {
  final String message;

  CloudflareMediaException(this.message);

  @override
  String toString() => message;
}
