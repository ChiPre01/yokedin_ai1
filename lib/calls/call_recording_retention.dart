import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:yoked_in/calls/call_listener_service.dart';
import 'package:yoked_in/calls/call_recording_models.dart';
import 'package:yoked_in/calls/call_recording_repository.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';

/// Enforces the 24-hour ceiling on call audio.
///
/// Audio is normally deleted as soon as its transcript is verified in
/// Firestore. This sweep is the backstop: any part still in R2 or on the
/// device a day after the call (a failed upload, a failed delete, a
/// transcription that never ran) is removed even if nobody opens the app's
/// minutes sheet again. The Worker also stamps recording uploads with a
/// 24-hour expiry, so R2 cleans itself up if the device never comes back.
class CallRecordingRetention {
  CallRecordingRetention({
    CallRecordingRepository? repository,
    CloudflareMediaService? media,
  })  : _repository = repository ?? CallRecordingRepository(),
        _media = media ?? CloudflareMediaService.instance;

  static const Duration audioRetention = Duration(hours: 24);

  final CallRecordingRepository _repository;
  final CloudflareMediaService _media;

  /// Deletes every expired recording part owned by the signed-in account.
  ///
  /// Returns how many sessions were cleaned up. Failures are logged per
  /// session so one unreachable recording cannot block the rest.
  Future<int> sweepExpiredAudio({DateTime? now}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return 0;

    final cutoff = (now ?? DateTime.now()).subtract(audioRetention);

    List<CallRecordingSession> sessions;
    try {
      sessions = await _repository.sessionsForOwner(uid);
    } catch (error) {
      debugPrint('Call audio retention could not list recordings: $error');
      return 0;
    }

    var cleaned = 0;
    for (final session in sessions) {
      if (!session.startedAt.isBefore(cutoff)) continue;
      if (session.audioDeletedAt != null) continue;

      try {
        if (await _expireSession(session)) cleaned += 1;
      } catch (error) {
        debugPrint('Call audio retention failed for ${session.id}: $error');
      }
    }

    return cleaned;
  }

  Future<bool> _expireSession(CallRecordingSession session) async {
    final chunks = await _repository.loadChunks(session.id);
    var hadAudio = false;

    for (final chunk in chunks) {
      final mediaKey = chunk.mediaKey;
      if (mediaKey != null && mediaKey.isNotEmpty) {
        hadAudio = true;
        try {
          await _media.deleteMedia(mediaKey);
        } catch (error) {
          debugPrint('Expired call audio could not be deleted: $error');
          continue;
        }
        await _repository.updateChunk(session.id, chunk.chunkId, {
          'mediaKey': null,
          'mediaDeletedAt': DateTime.now(),
        });
      }

      final localPath = chunk.localPath;
      if (localPath != null && localPath.isNotEmpty) {
        hadAudio = true;
        final removed =
            await CallListenerService.instance.deleteLocalPart(localPath);
        if (!removed) {
          debugPrint('Expired call audio stays on the device: $localPath');
        }
      }
    }

    if (!hadAudio) return false;

    await _repository.updateSession(session.id, {
      'state': callRecordingStateToName(CallRecordingState.audioDeleted),
      'audioDeletedAt': DateTime.now(),
      'error': session.hasTranscript
          ? null
          : 'The audio expired after 24 hours before it could be transcribed.',
    });

    return true;
  }
}
