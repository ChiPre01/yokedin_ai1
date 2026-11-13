import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

/// Conversation a call belongs to.
///
/// ZEGO passes this between the caller and the callee as invitation
/// `customData`, so both devices can link their own recording to the same chat
/// or group without an extra lookup.
class CallConversationInfo {
  const CallConversationInfo({
    required this.conversationId,
    required this.conversationType,
    required this.title,
  });

  /// Marks our own payload so a legacy value (a plain display name) is ignored
  /// instead of being misread as a conversation id.
  static const String _prefix = 'yokedin-call:';

  final String conversationId;
  final String conversationType; // 'private' or 'group'
  final String title;

  bool get isValid =>
      conversationId.isNotEmpty &&
      (conversationType == 'private' || conversationType == 'group');

  String toCustomData() => '$_prefix'
      '${jsonEncode({
    'type': conversationType,
    'id': conversationId,
    'title': title,
  })}';

  static CallConversationInfo? tryParse(String? raw) {
    final value = raw?.trim() ?? '';
    if (!value.startsWith(_prefix)) return null;

    try {
      final decoded = jsonDecode(value.substring(_prefix.length));
      if (decoded is! Map) return null;

      final info = CallConversationInfo(
        conversationId: (decoded['id'] ?? '').toString(),
        conversationType: (decoded['type'] ?? '').toString(),
        title: (decoded['title'] ?? '').toString(),
      );
      return info.isValid ? info : null;
    } catch (_) {
      return null;
    }
  }
}

/// One timed line of a transcription result.
class CallTranscriptSegment {
  const CallTranscriptSegment({
    required this.startSeconds,
    required this.endSeconds,
    required this.text,
  });

  final double startSeconds;
  final double endSeconds;
  final String text;

  Map<String, dynamic> toMap() => {
        'start': startSeconds,
        'end': endSeconds,
        'text': text,
      };

  static CallTranscriptSegment? fromMap(dynamic value) {
    if (value is! Map) return null;
    final text = (value['text'] ?? '').toString().trim();
    if (text.isEmpty) return null;
    return CallTranscriptSegment(
      startSeconds: _toDouble(value['start']),
      endSeconds: _toDouble(value['end']),
      text: text,
    );
  }

  static double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

/// Lifecycle of a single uploaded recording part.
enum CallChunkState {
  /// Recorded on this device, not uploaded yet.
  local,

  /// Uploaded to R2; [CallRecordingChunk.mediaKey] is set.
  uploaded,

  /// Uploaded and transcribed; the text is stored against the chunk.
  transcribed,

  /// The local file is larger than the upload ceiling and cannot be used.
  tooLarge,

  /// A step failed; the audio is deliberately kept for a retry.
  failed,
}

CallChunkState callChunkStateFromName(String? name) {
  switch (name) {
    case 'uploaded':
      return CallChunkState.uploaded;
    case 'transcribed':
      return CallChunkState.transcribed;
    case 'tooLarge':
      return CallChunkState.tooLarge;
    case 'failed':
      return CallChunkState.failed;
    default:
      return CallChunkState.local;
  }
}

String callChunkStateToName(CallChunkState state) => state.name;

/// One sequential piece of a call recording.
class CallRecordingChunk {
  const CallRecordingChunk({
    required this.chunkId,
    required this.index,
    required this.sizeBytes,
    required this.durationMs,
    required this.state,
    this.startOffsetMs = 0,
    this.speakerUid,
    this.speakerName,
    this.localPath,
    this.mediaKey,
    this.transcriptText,
    this.segments = const [],
    this.attempts = 0,
    this.error,
    this.mediaDeletedAt,
  });

  final String chunkId;
  final int index;
  final int sizeBytes;
  final int durationMs;
  final CallChunkState state;

  /// Start of this part on the shared meeting timeline, in milliseconds since
  /// the meeting recording began, corrected for this device's clock offset.
  final int startOffsetMs;

  /// Who recorded this part. Minutes attribute the words to "`<name>` audio"
  /// because the audio came from that person's own device.
  final String? speakerUid;
  final String? speakerName;

  final String? localPath;
  final String? mediaKey;
  final String? transcriptText;
  final List<CallTranscriptSegment> segments;
  final int attempts;
  final String? error;
  final DateTime? mediaDeletedAt;

  bool get isTranscribed => (transcriptText ?? '').trim().isNotEmpty;
  bool get isUploaded => mediaKey != null && mediaKey!.isNotEmpty;

  CallRecordingChunk copyWith({
    CallChunkState? state,
    int? startOffsetMs,
    String? speakerUid,
    String? speakerName,
    String? localPath,
    String? mediaKey,
    String? transcriptText,
    List<CallTranscriptSegment>? segments,
    int? attempts,
    String? error,
    int? durationMs,
    DateTime? mediaDeletedAt,
  }) {
    return CallRecordingChunk(
      chunkId: chunkId,
      index: index,
      sizeBytes: sizeBytes,
      durationMs: durationMs ?? this.durationMs,
      state: state ?? this.state,
      startOffsetMs: startOffsetMs ?? this.startOffsetMs,
      speakerUid: speakerUid ?? this.speakerUid,
      speakerName: speakerName ?? this.speakerName,
      localPath: localPath ?? this.localPath,
      mediaKey: mediaKey ?? this.mediaKey,
      transcriptText: transcriptText ?? this.transcriptText,
      segments: segments ?? this.segments,
      attempts: attempts ?? this.attempts,
      error: error ?? this.error,
      mediaDeletedAt: mediaDeletedAt ?? this.mediaDeletedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'chunkId': chunkId,
        'index': index,
        'sizeBytes': sizeBytes,
        'durationMs': durationMs,
        'state': callChunkStateToName(state),
        'startOffsetMs': startOffsetMs,
        'speakerUid': speakerUid,
        'speakerName': speakerName,
        'localPath': localPath,
        'mediaKey': mediaKey,
        'transcriptText': transcriptText,
        'segments': segments.map((segment) => segment.toMap()).toList(),
        'attempts': attempts,
        'error': error,
        'mediaDeletedAt': mediaDeletedAt == null
            ? null
            : Timestamp.fromDate(mediaDeletedAt!),
        'updatedAt': FieldValue.serverTimestamp(),
      };

  static CallRecordingChunk fromMap(String id, Map<String, dynamic> map) {
    final rawSegments = map['segments'];
    final segments = rawSegments is List
        ? rawSegments
            .map(CallTranscriptSegment.fromMap)
            .whereType<CallTranscriptSegment>()
            .toList()
        : <CallTranscriptSegment>[];

    return CallRecordingChunk(
      chunkId: (map['chunkId'] ?? id).toString(),
      index: (map['index'] as num?)?.toInt() ?? 0,
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      state: callChunkStateFromName(map['state']?.toString()),
      startOffsetMs: (map['startOffsetMs'] as num?)?.toInt() ?? 0,
      speakerUid: map['speakerUid']?.toString(),
      speakerName: map['speakerName']?.toString(),
      localPath: map['localPath']?.toString(),
      mediaKey: map['mediaKey']?.toString(),
      transcriptText: map['transcriptText']?.toString(),
      segments: segments,
      attempts: (map['attempts'] as num?)?.toInt() ?? 0,
      error: map['error']?.toString(),
      mediaDeletedAt: map['mediaDeletedAt'] is Timestamp
          ? (map['mediaDeletedAt'] as Timestamp).toDate()
          : null,
    );
  }
}

/// Stage of the whole recording, used to drive the UI and to resume.
enum CallRecordingState {
  recording,
  completed, // all audio still on device / in R2
  transcribing,
  transcribed, // transcript saved in Firestore
  audioDeleted, // transcript saved and every audio copy deleted
  failed,
}

CallRecordingState callRecordingStateFromName(String? name) {
  switch (name) {
    case 'recording':
      return CallRecordingState.recording;
    case 'transcribing':
      return CallRecordingState.transcribing;
    case 'transcribed':
      return CallRecordingState.transcribed;
    case 'audioDeleted':
      return CallRecordingState.audioDeleted;
    case 'failed':
      return CallRecordingState.failed;
    default:
      return CallRecordingState.completed;
  }
}

String callRecordingStateToName(CallRecordingState state) => state.name;

/// A recorded call: one document per recording, with chunk sub-documents.
class CallRecordingSession {
  const CallRecordingSession({
    required this.id,
    required this.callId,
    required this.conversationId,
    required this.conversationType,
    required this.ownerUid,
    required this.ownerName,
    required this.startedAt,
    required this.state,
    this.meetingId,
    this.speakerUid,
    this.speakerName,
    this.endedAt,
    this.chunkCount = 0,
    this.durationSeconds = 0,
    this.transcriptText,
    this.transcriptSavedAt,
    this.audioDeletedAt,
    this.minuteId,
    this.error,
  });

  final String id;
  final String callId;
  final String conversationId;
  final String conversationType;
  final String ownerUid;
  final String ownerName;
  final DateTime startedAt;

  /// Set when this session is one participant's part of a shared meeting
  /// recording, so several devices contribute to one minutes document.
  final String? meetingId;
  final String? speakerUid;
  final String? speakerName;
  final DateTime? endedAt;
  final CallRecordingState state;
  final int chunkCount;
  final int durationSeconds;
  final String? transcriptText;
  final DateTime? transcriptSavedAt;
  final DateTime? audioDeletedAt;

  /// Set once minutes were generated from this transcript, so a second tap
  /// cannot silently create a duplicate minutes document.
  final String? minuteId;

  final String? error;

  bool get hasTranscript => (transcriptText ?? '').trim().isNotEmpty;

  Map<String, dynamic> toMap() => {
        'callId': callId,
        'conversationId': conversationId,
        'conversationType': conversationType,
        'ownerUid': ownerUid,
        'ownerName': ownerName,
        'meetingId': meetingId,
        'speakerUid': speakerUid ?? ownerUid,
        'speakerName': speakerName ?? ownerName,
        'startedAt': Timestamp.fromDate(startedAt),
        'endedAt': endedAt == null ? null : Timestamp.fromDate(endedAt!),
        'state': callRecordingStateToName(state),
        'chunkCount': chunkCount,
        'durationSeconds': durationSeconds,
        'transcriptText': transcriptText,
        'transcriptSavedAt': transcriptSavedAt == null
            ? null
            : Timestamp.fromDate(transcriptSavedAt!),
        'audioDeletedAt': audioDeletedAt == null
            ? null
            : Timestamp.fromDate(audioDeletedAt!),
        'minuteId': minuteId,
        'error': error,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  static CallRecordingSession fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final map = doc.data() ?? const <String, dynamic>{};
    return CallRecordingSession(
      id: doc.id,
      callId: (map['callId'] ?? '').toString(),
      conversationId: (map['conversationId'] ?? '').toString(),
      conversationType: (map['conversationType'] ?? 'private').toString(),
      ownerUid: (map['ownerUid'] ?? '').toString(),
      ownerName: (map['ownerName'] ?? 'You').toString(),
      meetingId: map['meetingId']?.toString(),
      speakerUid: map['speakerUid']?.toString(),
      speakerName: map['speakerName']?.toString(),
      startedAt: map['startedAt'] is Timestamp
          ? (map['startedAt'] as Timestamp).toDate()
          : DateTime.now(),
      endedAt: map['endedAt'] is Timestamp
          ? (map['endedAt'] as Timestamp).toDate()
          : null,
      state: callRecordingStateFromName(map['state']?.toString()),
      chunkCount: (map['chunkCount'] as num?)?.toInt() ?? 0,
      durationSeconds: (map['durationSeconds'] as num?)?.toInt() ?? 0,
      transcriptText: map['transcriptText']?.toString(),
      transcriptSavedAt: map['transcriptSavedAt'] is Timestamp
          ? (map['transcriptSavedAt'] as Timestamp).toDate()
          : null,
      audioDeletedAt: map['audioDeletedAt'] is Timestamp
          ? (map['audioDeletedAt'] as Timestamp).toDate()
          : null,
      minuteId: map['minuteId']?.toString(),
      error: map['error']?.toString(),
    );
  }
}
