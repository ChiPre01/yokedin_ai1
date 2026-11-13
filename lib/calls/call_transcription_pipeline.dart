import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:yoked_in/calls/call_listener_service.dart';
import 'package:yoked_in/calls/call_meeting_models.dart';
import 'package:yoked_in/calls/call_meeting_repository.dart';
import 'package:yoked_in/calls/call_recording_models.dart';
import 'package:yoked_in/calls/call_recording_repository.dart';
import 'package:yoked_in/calls/call_transcription_api.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';

class CallPipelineProgress {
  const CallPipelineProgress({
    required this.label,
    required this.completed,
    required this.total,
  });

  final String label;
  final int completed;
  final int total;

  double get fraction => total <= 0 ? 0 : (completed / total).clamp(0, 1);
}

class CallPipelineResult {
  const CallPipelineResult({
    required this.sessionId,
    required this.transcriptText,
    required this.durationSeconds,
    required this.partCount,
    required this.audioDeleted,
  });

  final String sessionId;
  final String transcriptText;
  final int durationSeconds;
  final int partCount;

  /// True only when every uploaded part was deleted from R2 and from the
  /// device. False means the transcript is safe but some audio remains.
  final bool audioDeleted;
}

/// Runs the recording → transcript workflow for one recorded call.
///
/// Order is fixed and each step is idempotent, so running it again after a
/// crash or a network error resumes instead of duplicating work:
///
/// 1. upload each locally recorded part that is not uploaded yet;
/// 2. transcribe each uploaded part that has no transcript yet;
/// 3. assemble the parts in order;
/// 4. save the transcript and read it back to verify it persisted;
/// 5. only then delete every R2 object and local file.
///
/// If any step fails, audio is deliberately kept so the work can be retried.
class CallTranscriptionPipeline {
  CallTranscriptionPipeline({
    CallRecordingRepository? repository,
    CloudflareMediaService? media,
    CallTranscriptionApi? api,
    CallListenerService? listener,
    CallMeetingRepository? meetings,
  })  : _repository = repository ?? CallRecordingRepository(),
        _media = media ?? CloudflareMediaService.instance,
        _api = api ?? CallTranscriptionApi(),
        _listener = listener ?? CallListenerService.instance,
        _meetings = meetings ?? CallMeetingRepository();

  /// One retry per part on top of the Worker's own provider retry.
  static const int _transcribeAttempts = 2;
  static const Duration _retryDelay = Duration(seconds: 2);

  final CallRecordingRepository _repository;
  final CloudflareMediaService _media;
  final CallTranscriptionApi _api;
  final CallListenerService _listener;
  final CallMeetingRepository _meetings;

  Future<CallPipelineResult> run({
    required String sessionId,
    void Function(CallPipelineProgress)? onProgress,
  }) async {
    final session = await _repository.loadSession(sessionId);
    if (session == null) {
      throw const CallPipelineException(
        'This call recording is no longer available.',
      );
    }

    var chunks = await _repository.loadChunks(sessionId);
    if (chunks.isEmpty) {
      throw const CallPipelineException(
        'No audio was saved for this call, so there is nothing to transcribe.',
      );
    }

    final tooLarge = chunks.where((c) => c.state == CallChunkState.tooLarge);
    if (tooLarge.isNotEmpty) {
      throw CallPipelineException(
        'Recording part ${tooLarge.first.chunkId} is larger than 25 MB and '
        'cannot be uploaded. The audio has been kept.',
      );
    }

    // ---------------- 1. Upload ----------------
    for (var index = 0; index < chunks.length; index++) {
      final chunk = chunks[index];
      onProgress?.call(
        CallPipelineProgress(
          label: 'Uploading part ${index + 1} of ${chunks.length}',
          completed: index,
          total: chunks.length,
        ),
      );

      // Already uploaded e.g. by an interrupted run: never upload twice.
      if (chunk.isUploaded) continue;

      if (chunk.localPath == null || chunk.localPath!.isEmpty) {
        throw CallPipelineException(
          'Recording part ${chunk.chunkId} is missing on this device. '
          'The audio has been kept.',
        );
      }

      Map<String, dynamic> uploaded;
      try {
        uploaded = await _media.uploadFile(
          XFile(chunk.localPath!, name: '${chunk.chunkId}.mp4'),
          purpose:
              session.conversationType == 'group' ? 'group' : 'chat',
          chatId: session.conversationType == 'group'
              ? null
              : session.conversationId,
          groupId: session.conversationType == 'group'
              ? session.conversationId
              : null,
          category: 'audio',
          contentTypeOverride: 'audio/mp4',
        );
      } catch (error) {
        throw CallPipelineException(
          'Part ${index + 1} could not be uploaded. '
          '${_errorMessage(error)} The audio has been kept.',
        );
      }

      final mediaKey = (uploaded['key'] ?? '').toString();
      if (mediaKey.isEmpty) {
        throw CallPipelineException(
          'Part ${index + 1} was uploaded without a storage key. '
          'The audio has been kept.',
        );
      }

      chunks[index] = chunk.copyWith(
        state: CallChunkState.uploaded,
        mediaKey: mediaKey,
      );
      await _repository.updateChunk(sessionId, chunk.chunkId, {
        'state': callChunkStateToName(CallChunkState.uploaded),
        'mediaKey': mediaKey,
        'error': null,
      });
    }

    // ---------------- 2. Transcribe ----------------
    for (var index = 0; index < chunks.length; index++) {
      final chunk = chunks[index];
      onProgress?.call(
        CallPipelineProgress(
          label: 'Transcribing part ${index + 1} of ${chunks.length}',
          completed: index,
          total: chunks.length,
        ),
      );

      if (chunk.isTranscribed) continue;
      if (!chunk.isUploaded) {
        throw CallPipelineException(
          'Part ${chunk.chunkId} is not uploaded yet. '
          'The audio has been kept.',
        );
      }

      ChunkTranscription? transcription;
      Object? lastError;

      for (var attempt = 1; attempt <= _transcribeAttempts; attempt++) {
        try {
          transcription = await _api.transcribeChunk(
            mediaKey: chunk.mediaKey!,
            chunkIndex: chunk.index,
            conversationId: session.conversationId,
            conversationType: session.conversationType,
          );
          break;
        } catch (error) {
          lastError = error;
          debugPrint(
            'Call pipeline: transcription attempt $attempt failed for '
            '${chunk.chunkId}.',
          );
          if (attempt < _transcribeAttempts) {
            await Future<void>.delayed(_retryDelay);
          }
        }
      }

      if (transcription == null) {
        await _repository.updateChunk(sessionId, chunk.chunkId, {
          'state': callChunkStateToName(CallChunkState.failed),
          'attempts': chunk.attempts + 1,
          'error': _errorMessage(lastError),
        });
        throw CallPipelineException(
          'Part ${index + 1} could not be transcribed. '
          '${_errorMessage(lastError)} The audio has been kept.',
        );
      }

      final segments = transcription.segments;
      final text = transcription.text.trim();

      chunks[index] = chunk.copyWith(
        state: CallChunkState.transcribed,
        transcriptText: text,
        segments: segments,
        attempts: chunk.attempts + 1,
        durationMs: transcription.durationSeconds > 0
            ? (transcription.durationSeconds * 1000).round()
            : chunk.durationMs,
        error: '',
      );

      await _repository.updateChunk(sessionId, chunk.chunkId, {
        'state': callChunkStateToName(CallChunkState.transcribed),
        'transcriptText': text,
        'segments': segments.map((segment) => segment.toMap()).toList(),
        'attempts': chunk.attempts + 1,
        'durationMs': chunks[index].durationMs,
        'error': null,
      });

      // Publish this part to the shared meeting so any participant can build
      // the minutes without touching another person's audio. The Worker only
      // lets a caller read its own media key, so transcribing happens here on
      // the recorder's device and only the text travels.
      final meetingId = (session.meetingId ?? '').trim();
      if (meetingId.isNotEmpty) {
        try {
          await _meetings.addContribution(
            meetingId,
            CallMeetingContribution(
              uid: (session.speakerUid ?? session.ownerUid),
              name: (session.speakerName ?? session.ownerName),
              chunkId: chunk.chunkId,
              startMs: chunk.startOffsetMs,
              durationMs: chunks[index].durationMs,
              text: text,
              segments: segments,
            ),
          );
        } catch (error) {
          debugPrint(
            'Call pipeline: could not publish ${chunk.chunkId} to the meeting: '
            '$error',
          );
        }
      }
    }

    // ---------------- 3. Assemble ----------------
    onProgress?.call(
      const CallPipelineProgress(
        label: 'Assembling the transcript',
        completed: 0,
        total: 1,
      ),
    );

    final transcript = _assembleTranscript(chunks);
    if (transcript.trim().isEmpty) {
      throw const CallPipelineException(
        'No speech was recognised in this call. The audio has been kept.',
      );
    }

    if (chunks.any((chunk) => !chunk.isTranscribed)) {
      throw const CallPipelineException(
        'Not every recording part was transcribed. The audio has been kept.',
      );
    }

    final durationSeconds = chunks.fold<int>(
      0,
      (total, chunk) => total + (chunk.durationMs / 1000).round(),
    );

    // ---------------- 4. Save and VERIFY ----------------
    onProgress?.call(
      const CallPipelineProgress(
        label: 'Saving the transcript',
        completed: 0,
        total: 1,
      ),
    );

    await _repository.updateSession(sessionId, {
      'state': callRecordingStateToName(CallRecordingState.transcribing),
      'transcriptText': transcript,
      'transcriptSavedAt': DateTime.now(),
      'durationSeconds': durationSeconds,
    });

    final verified = await _repository.verifyTranscriptSaved(
      sessionId,
      transcript,
    );

    if (!verified) {
      throw const CallPipelineException(
        'The transcript could not be verified in Firestore, so the audio has '
        'been kept. Please try again.',
      );
    }

    // ---------------- 5. Delete audio ----------------
    var deletedEverywhere = true;
    final failures = <String>[];

    for (final chunk in chunks) {
      final mediaKey = chunk.mediaKey;
      if (mediaKey == null || mediaKey.isEmpty) continue;

      try {
        await _media.deleteMedia(mediaKey);
      } catch (error) {
        deletedEverywhere = false;
        failures.add(_errorMessage(error));
        continue;
      }

      await _repository.updateChunk(sessionId, chunk.chunkId, {
        'mediaKey': null,
        'mediaDeletedAt': DateTime.now(),
      });

      if (chunk.localPath != null && chunk.localPath!.isNotEmpty) {
        final removed = await _listener.deleteLocalPart(chunk.localPath!);
        if (!removed) deletedEverywhere = false;
      }
    }

    await _repository.updateSession(sessionId, {
      'state': callRecordingStateToName(
        deletedEverywhere
            ? CallRecordingState.audioDeleted
            : CallRecordingState.transcribed,
      ),
      'audioDeletedAt': deletedEverywhere ? DateTime.now() : null,
      'error': deletedEverywhere
          ? null
          : 'The transcript is saved, but some audio could not be deleted: '
              '${failures.join(' ')}',
    });

    onProgress?.call(
      const CallPipelineProgress(
        label: 'Done',
        completed: 1,
        total: 1,
      ),
    );

    return CallPipelineResult(
      sessionId: sessionId,
      transcriptText: transcript,
      durationSeconds: durationSeconds,
      partCount: chunks.length,
      audioDeleted: deletedEverywhere,
    );
  }

  /// Joins parts in order and removes words repeated at a boundary.
  ///
  /// Parts are rotated recording sessions, so they do not overlap. The overlap
  /// removal still runs: if a future recorder adds a small overlap, the merged
  /// transcript must not contain the repeated words twice.
  String _assembleTranscript(List<CallRecordingChunk> chunks) {
    final ordered = [...chunks]..sort((a, b) => a.index.compareTo(b.index));
    final parts = <String>[];

    for (final chunk in ordered) {
      final text = (chunk.transcriptText ?? '').trim();
      if (text.isNotEmpty) parts.add(text);
    }

    if (parts.isEmpty) return '';

    var merged = parts.first;
    for (final part in parts.skip(1)) {
      merged = _appendWithoutOverlap(merged, part);
    }
    return merged;
  }

  String _appendWithoutOverlap(String existing, String addition) {
    final existingWords = existing.split(RegExp(r'\s+'));
    final additionWords = addition.split(RegExp(r'\s+'));

    const maxOverlap = 12;
    final limit = existingWords.length < maxOverlap
        ? existingWords.length
        : maxOverlap;

    for (var size = limit; size > 0; size--) {
      final tail = existingWords.sublist(existingWords.length - size);
      final head = additionWords.take(size).toList();
      if (_sameWords(tail, head)) {
        return '$existing ${additionWords.skip(size).join(' ')}'.trim();
      }
    }

    return '$existing $addition';
  }

  bool _sameWords(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (_normaliseWord(a[index]) != _normaliseWord(b[index])) return false;
    }
    return true;
  }

  String _normaliseWord(String word) =>
      word.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  String _errorMessage(Object? error) {
    if (error == null) return '';
    if (error is CallTranscriptionException) return error.message;
    if (error is CloudflareMediaException) return error.message;
    return error.toString().replaceFirst('Exception: ', '');
  }
}

class CallPipelineException implements Exception {
  const CallPipelineException(this.message);

  final String message;

  @override
  String toString() => message;
}
