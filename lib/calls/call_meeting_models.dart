import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:yoked_in/calls/call_recording_models.dart';

/// Lifecycle of the one recording shared by every participant of a call.
///
/// A meeting exists so that several phones can contribute their own audio to a
/// single minutes document instead of one phone trying to hear the whole room.
enum CallMeetingStatus { recording, stopped, compiled }

CallMeetingStatus callMeetingStatusFromName(String? name) {
  switch (name) {
    case 'recording':
      return CallMeetingStatus.recording;
    case 'compiled':
      return CallMeetingStatus.compiled;
    default:
      return CallMeetingStatus.stopped;
  }
}

String callMeetingStatusToName(CallMeetingStatus status) => status.name;

/// Where one participant stands in a shared meeting recording.
///
/// * `invited` - saw the recording alert, has not answered yet.
/// * `recording` - this device is contributing its own microphone audio.
/// * `declined` - answered "not now"; nothing is captured.
/// * `stopped` - stopped contributing (or the recorder stopped).
/// * `left` - the call ended or the device stopped answering.
class CallMeetingParticipant {
  const CallMeetingParticipant({
    required this.uid,
    required this.name,
    required this.state,
    this.joinedAtMs = 0,
    this.lastSeenAtMs = 0,
    this.segments = 0,
  });

  final String uid;
  final String name;
  final String state;
  final int joinedAtMs;
  final int lastSeenAtMs;
  final int segments;

  bool get isContributing => state == 'recording';

  Map<String, dynamic> toMap() => {
        'name': name,
        'state': state,
        'joinedAt': joinedAtMs > 0
            ? Timestamp.fromMillisecondsSinceEpoch(joinedAtMs)
            : FieldValue.serverTimestamp(),
        'lastSeenAt': FieldValue.serverTimestamp(),
        'segments': segments,
      };

  static CallMeetingParticipant? fromEntry(String uid, dynamic value) {
    if (value is! Map) return null;
    final map = Map<String, dynamic>.from(value);
    return CallMeetingParticipant(
      uid: uid,
      name: (map['name'] ?? 'Participant').toString().trim().isEmpty
          ? 'Participant'
          : (map['name'] ?? 'Participant').toString(),
      state: (map['state'] ?? 'invited').toString(),
      joinedAtMs: _millisecondsOf(map['joinedAt']),
      lastSeenAtMs: _millisecondsOf(map['lastSeenAt']),
      segments: (map['segments'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One transcribed recording part contributed by a participant.
///
/// [startMs] is measured on the shared meeting clock (milliseconds since
/// [CallMeeting.startedAtMs]), so parts recorded on different phones can be
/// placed on one timeline even though their device clocks differ.
class CallMeetingContribution {
  const CallMeetingContribution({
    required this.uid,
    required this.name,
    required this.chunkId,
    required this.startMs,
    required this.durationMs,
    required this.text,
    this.segments = const [],
  });

  final String uid;
  final String name;
  final String chunkId;
  final int startMs;
  final int durationMs;
  final String text;
  final List<CallTranscriptSegment> segments;

  String get documentId => '${uid}_$chunkId';

  /// Label used everywhere a contribution is attributed to a person.
  ///
  /// "audio" keeps the attribution honest: the words were captured from that
  /// participant's own device, but somebody else standing next to them could
  /// still have been recorded, so the minutes must not claim a verified
  /// speaker identity.
  String get speakerLabel => audioLabelFor(name);

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'name': name,
        'chunkId': chunkId,
        'startMs': startMs,
        'durationMs': durationMs,
        'text': text,
        'segments': segments.map((segment) => segment.toMap()).toList(),
      };

  static CallMeetingContribution? fromMap(
    String documentId,
    Map<String, dynamic> map,
  ) {
    final text = (map['text'] ?? '').toString().trim();
    final rawSegments = map['segments'];
    final segments = rawSegments is List
        ? rawSegments
            .map(CallTranscriptSegment.fromMap)
            .whereType<CallTranscriptSegment>()
            .toList()
        : <CallTranscriptSegment>[];

    if (text.isEmpty && segments.isEmpty) return null;

    return CallMeetingContribution(
      uid: (map['uid'] ?? '').toString(),
      name: (map['name'] ?? 'Participant').toString(),
      chunkId: (map['chunkId'] ?? documentId).toString(),
      startMs: (map['startMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      text: text.isNotEmpty
          ? text
          : segments.map((segment) => segment.text).join(' ').trim(),
      segments: segments,
    );
  }
}

/// The Firestore document every participant of a call writes to.
class CallMeeting {
  const CallMeeting({
    required this.id,
    required this.callId,
    required this.conversationId,
    required this.conversationType,
    required this.title,
    required this.status,
    required this.startedAtMs,
    required this.activeRecorderUid,
    required this.activeRecorderName,
    required this.recordingActive,
    required this.heartbeatAtMs,
    required this.participants,
    required this.recorders,
    this.stopReason,
    this.stoppedByName,
    this.stopNoticeAtMs = 0,
    this.compiledMinuteId,
    this.compiledAtMs = 0,
  });

  final String id;
  final String callId;
  final String conversationId;
  final String conversationType;
  final String title;
  final CallMeetingStatus status;

  /// Shared start of the timeline, from a Firestore server timestamp.
  final int startedAtMs;
  final String activeRecorderUid;
  final String activeRecorderName;
  final bool recordingActive;
  final int heartbeatAtMs;

  /// Participants who are allowed to see and generate the minutes, including
  /// people who joined after recording started or never contributed.
  final Map<String, CallMeetingParticipant> participants;

  /// Everyone who has recorded at least one part of this meeting.
  final List<String> recorders;

  final String? stopReason;
  final String? stoppedByName;

  /// Changes every time the recording stops, so a device shows the
  /// "continue recording?" alert once per stop.
  final int stopNoticeAtMs;

  final String? compiledMinuteId;
  final int compiledAtMs;

  DateTime get startedAt => DateTime.fromMillisecondsSinceEpoch(startedAtMs);

  bool get hasCompiledMinutes =>
      (compiledMinuteId ?? '').trim().isNotEmpty;

  /// The active recorder stopped sending heartbeats, so another participant
  /// may take over without waiting for the call to end.
  bool recorderIsStale(int nowMs, {int thresholdMs = 45000}) {
    if (!recordingActive || heartbeatAtMs <= 0) return false;
    return nowMs - heartbeatAtMs > thresholdMs;
  }

  List<CallMeetingParticipant> get sortedParticipants {
    final list = participants.values.toList();
    list.sort((a, b) => a.joinedAtMs.compareTo(b.joinedAtMs));
    return list;
  }

  Map<String, dynamic> toMap() => {
        'callId': callId,
        'conversationId': conversationId,
        'conversationType': conversationType,
        'title': title,
        'status': callMeetingStatusToName(status),
        'startedAtMs': startedAtMs,
        'activeRecorderUid': activeRecorderUid,
        'activeRecorderName': activeRecorderName,
        'recordingActive': recordingActive,
        'recorders': recorders,
        'stopReason': stopReason,
        'stoppedByName': stoppedByName,
        'stopNoticeAtMs': stopNoticeAtMs,
        'compiledMinuteId': compiledMinuteId,
        'updatedAt': serverTimestamp,
      };

  static CallMeeting fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final map = doc.data() ?? const <String, dynamic>{};

    final participants = <String, CallMeetingParticipant>{};
    final rawParticipants = map['participants'];
    if (rawParticipants is Map) {
      for (final entry in rawParticipants.entries) {
        final uid = entry.key.toString();
        final participant =
            CallMeetingParticipant.fromEntry(uid, entry.value);
        if (participant != null) participants[uid] = participant;
      }
    }

    final rawRecorders = map['recorders'];
    final recorders = rawRecorders is List
        ? rawRecorders.map((value) => value.toString()).toList()
        : <String>[];

    return CallMeeting(
      id: doc.id,
      callId: (map['callId'] ?? '').toString(),
      conversationId: (map['conversationId'] ?? '').toString(),
      conversationType: (map['conversationType'] ?? 'private').toString(),
      title: (map['title'] ?? '').toString(),
      status: callMeetingStatusFromName(map['status']?.toString()),
      startedAtMs: _millisecondsOf(map['startedAt'] ?? map['startedAtMs']),
      activeRecorderUid: (map['activeRecorderUid'] ?? '').toString(),
      activeRecorderName: (map['activeRecorderName'] ?? '').toString(),
      recordingActive: map['recordingActive'] == true,
      heartbeatAtMs: _millisecondsOf(map['recorderHeartbeatAt']),
      participants: participants,
      recorders: recorders,
      stopReason: map['stopReason']?.toString(),
      stoppedByName: map['stoppedByName']?.toString(),
      stopNoticeAtMs: _millisecondsOf(map['stopNoticeAt']),
      compiledMinuteId: map['compiledMinuteId']?.toString(),
      compiledAtMs: _millisecondsOf(map['compiledAt']),
    );
  }

  /// One stable meeting id per ZEGO call, so no participant has to ask anyone
  /// which recording to join.
  static String meetingIdForCallId(String callId) {
    final sanitised = callId
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (sanitised.isEmpty) return 'call_unknown';
    return sanitised.length <= 120 ? sanitised : sanitised.substring(0, 120);
  }
}

/// How a contribution is attributed in the generated minutes.
///
/// The trailing "audio" makes clear the words were captured from that person's
/// own device, not that the app recognised their voice.
String audioLabelFor(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Participant audio';
  if (trimmed.toLowerCase().endsWith(' audio')) return trimmed;
  return '$trimmed audio';
}

dynamic get serverTimestamp => FieldValue.serverTimestamp();

int _millisecondsOf(dynamic value) {
  if (value is Timestamp) return value.millisecondsSinceEpoch;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
