import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:yoked_in/calls/call_meeting_models.dart';

/// Outcome of asking to become the meeting's active recorder.
class RecorderClaim {
  const RecorderClaim({
    required this.granted,
    this.meeting,
    this.holderName,
  });

  final bool granted;

  /// The stored meeting document, re-read after the transaction so its server
  /// timestamps are resolved.
  final CallMeeting? meeting;

  /// Set when another participant is already recording this meeting.
  final String? holderName;
}

/// Firestore persistence for shared meeting recordings.
///
/// The meeting document holds one shared timeline and one "active recorder"
/// slot; the audio parts of every participant are stored in a subcollection so
/// each device only writes its own transcriptions.
class CallMeetingRepository {
  CallMeetingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const String collectionName = 'call_meetings';

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _meetings =>
      _firestore.collection(collectionName);

  DocumentReference<Map<String, dynamic>> document(String meetingId) =>
      _meetings.doc(meetingId);

  CollectionReference<Map<String, dynamic>> _contributions(String meetingId) =>
      document(meetingId).collection('contributions');

  Stream<CallMeeting?> watch(String meetingId) {
    return document(meetingId).snapshots().map(
          (snapshot) =>
              snapshot.exists ? CallMeeting.fromDoc(snapshot) : null,
        );
  }

  Future<CallMeeting?> load(String meetingId) async {
    final snapshot = await document(meetingId).get();
    if (!snapshot.exists) return null;
    return CallMeeting.fromDoc(snapshot);
  }

  /// Creates the meeting if it does not exist yet, or takes the recorder role
  /// over when it is free or its holder stopped answering.
  ///
  /// Returns [RecorderClaim.granted] false with the holder's name while
  /// somebody else is actively recording, which is what the UI turns into
  /// "meeting currently recorded by `<name>`".
  Future<RecorderClaim> claimRecorder({
    required String meetingId,
    required String callId,
    required String conversationId,
    required String conversationType,
    required String title,
    required String uid,
    required String name,
  }) async {
    final reference = document(meetingId);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final claim = await _firestore.runTransaction<RecorderClaim>((transaction) async {
      final snapshot = await transaction.get(reference);

      if (!snapshot.exists) {
        transaction.set(reference, {
          'callId': callId,
          'conversationId': conversationId,
          'conversationType': conversationType,
          'title': title,
          'status': callMeetingStatusToName(CallMeetingStatus.recording),
          'startedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
          'activeRecorderUid': uid,
          'activeRecorderName': name,
          'recordingActive': true,
          'recorderHeartbeatAt': FieldValue.serverTimestamp(),
          'participants': {
            uid: {
              'name': name,
              'state': 'recording',
              'joinedAt': FieldValue.serverTimestamp(),
              'lastSeenAt': FieldValue.serverTimestamp(),
            },
          },
          'recorders': [uid],
          'stopReason': null,
          'stoppedByName': null,
          'stopNoticeAt': 0,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return const RecorderClaim(granted: true);
      }

      final meeting = CallMeeting.fromDoc(snapshot);
      final holder = meeting.activeRecorderUid;
      final heldByAnother =
          meeting.recordingActive && holder.isNotEmpty && holder != uid;
      final holderIsStale = meeting.recorderIsStale(nowMs);

      if (heldByAnother && !holderIsStale) {
        return RecorderClaim(
          granted: false,
          meeting: meeting,
          holderName: meeting.activeRecorderName.isEmpty
              ? 'another participant'
              : meeting.activeRecorderName,
        );
      }

      transaction.set(
        reference,
        {
          // Refill the meeting identity on every claim. A document created by
          // an older build (or by a participant write that happened before the
          // claim) can be missing its conversation id, and the minutes request
          // is then rejected by the Worker.
          'callId': callId,
          'conversationId': conversationId,
          'conversationType': conversationType,
          'title': title,
          if (meeting.startedAtMs <= 0)
            'startedAt': FieldValue.serverTimestamp(),
          'status': callMeetingStatusToName(CallMeetingStatus.recording),
          'activeRecorderUid': uid,
          'activeRecorderName': name,
          'recordingActive': true,
          'recorderHeartbeatAt': FieldValue.serverTimestamp(),
          'stopReason': null,
          'stoppedByName': null,
          'stopNoticeAt': 0,
          'recorders': FieldValue.arrayUnion([uid]),
          'participants.$uid': {
            'name': name,
            'state': 'recording',
            'lastSeenAt': FieldValue.serverTimestamp(),
          },
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      return RecorderClaim(granted: true, meeting: meeting);
    });

    if (!claim.granted) return claim;

    // Re-read so [startedAt] is the resolved server timestamp: every device
    // must place its parts on the same timeline.
    final stored = await load(meetingId);
    return RecorderClaim(granted: true, meeting: stored ?? claim.meeting);
  }

  /// Measures how far this device's clock is from the Firestore server clock.
  ///
  /// A part's start is stamped as `localStart + offset - meeting.startedAtMs`,
  /// so contributions from different phones sort correctly even when their
  /// clocks disagree by a few seconds.
  Future<int> measureServerOffsetMs({
    required String meetingId,
    required String uid,
  }) async {
    final reference = document(meetingId);
    final before = DateTime.now().millisecondsSinceEpoch;

    await reference.set(
      {
        'participants.$uid.lastSeenAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    final snapshot = await reference.get();
    final after = DateTime.now().millisecondsSinceEpoch;

    final participants = snapshot.data()?['participants'];
    if (participants is! Map) return 0;
    final mine = participants[uid];
    if (mine is! Map) return 0;
    final seen = mine['lastSeenAt'];
    if (seen is! Timestamp) return 0;

    final midpoint = (before + after) ~/ 2;
    return seen.millisecondsSinceEpoch - midpoint;
  }

  Future<void> upsertParticipant({
    required String meetingId,
    required String uid,
    required String name,
    required String state,
  }) async {
    await document(meetingId).set(
      {
        'participants.$uid': {
          'name': name,
          'state': state,
          'joinedAt': FieldValue.serverTimestamp(),
          'lastSeenAt': FieldValue.serverTimestamp(),
        },
      },
      SetOptions(merge: true),
    );
  }

  Future<void> heartbeat({
    required String meetingId,
    required String uid,
  }) async {
    await document(meetingId).set(
      {
        'status': callMeetingStatusToName(CallMeetingStatus.recording),
        'recordingActive': true,
        'recorderHeartbeatAt': FieldValue.serverTimestamp(),
        'participants.$uid.lastSeenAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// Ends this device's part of the meeting recording.
  ///
  /// When [uid] held the recorder role, the meeting is marked stopped with a
  /// fresh [CallMeeting.stopNoticeAtMs], which is what makes every other
  /// participant see the "continue recording?" alert.
  Future<void> release({
    required String meetingId,
    required String uid,
    required String name,
    required String reason,
  }) async {
    final reference = document(meetingId);

    await _firestore.runTransaction<void>((transaction) async {
      final snapshot = await transaction.get(reference);
      if (!snapshot.exists) return;

      final meeting = CallMeeting.fromDoc(snapshot);
      if (meeting.activeRecorderUid != uid) {
        transaction.set(
          reference,
          {
            'participants.$uid.state': 'stopped',
            'participants.$uid.lastSeenAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        return;
      }

      transaction.set(
        reference,
        {
          'status': callMeetingStatusToName(CallMeetingStatus.stopped),
          'recordingActive': false,
          'stopReason': reason,
          'stoppedByName': name,
          'stopNoticeAt': DateTime.now().millisecondsSinceEpoch,
          'participants.$uid.state': 'stopped',
          'participants.$uid.lastSeenAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    });
  }

  /// Stores one transcribed part. The document id is derived from the speaker
  /// and the part, so a retried upload updates instead of duplicating.
  Future<void> addContribution(
    String meetingId,
    CallMeetingContribution contribution,
  ) async {
    await _contributions(meetingId)
        .doc(contribution.documentId)
        .set(
          {
            ...contribution.toMap(),
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
  }

  Future<List<CallMeetingContribution>> loadContributions(
    String meetingId,
  ) async {
    final snapshot = await _contributions(meetingId).get();
    final contributions = snapshot.docs
        .map((doc) => CallMeetingContribution.fromMap(doc.id, doc.data()))
        .whereType<CallMeetingContribution>()
        .toList()
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    return contributions;
  }

  Future<void> markCompiled({
    required String meetingId,
    required String minuteId,
    required String uid,
  }) async {
    await document(meetingId).set(
      {
        'status': callMeetingStatusToName(CallMeetingStatus.compiled),
        'compiledMinuteId': minuteId,
        'compiledByUid': uid,
        'compiledAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// The most recent meetings recorded in a conversation, newest first.
  ///
  /// Filters on [conversationId] only, so it needs no composite index; the
  /// conversation type is filtered on the client.
  Future<List<CallMeeting>> meetingsForConversation({
    required String conversationId,
    required String conversationType,
    int limit = 10,
  }) async {
    if (conversationId.trim().isEmpty) return const [];

    try {
      final snapshot = await _meetings
          .where('conversationId', isEqualTo: conversationId.trim())
          .limit(limit)
          .get();

      final meetings = snapshot.docs
          .map(CallMeeting.fromDoc)
          .where((meeting) => meeting.conversationType == conversationType)
          .toList()
        ..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));

      return meetings;
    } catch (error) {
      debugPrint('Call meetings query failed: $error');
      return const [];
    }
  }
}
