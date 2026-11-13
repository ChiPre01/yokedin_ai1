import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:yoked_in/calls/call_recording_models.dart';

/// Firestore persistence for call recordings and their chunks.
///
/// Documents are written incrementally so an interrupted pipeline can resume:
/// every chunk keeps its own upload and transcription state, and the session
/// keeps the assembled transcript plus the deletion flags.
class CallRecordingRepository {
  CallRecordingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const String collectionName = 'call_recordings';

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _sessions =>
      _firestore.collection(collectionName);

  CollectionReference<Map<String, dynamic>> _chunks(String sessionId) =>
      _sessions.doc(sessionId).collection('chunks');

  /// Creates the session document and returns its id.
  Future<String> createSession({
    required String callId,
    required String conversationId,
    required String conversationType,
    required String ownerUid,
    required String ownerName,
    required DateTime startedAt,
    String? meetingId,
    String? speakerUid,
    String? speakerName,
  }) async {
    final doc = await _sessions.add(
      CallRecordingSession(
        id: '',
        callId: callId,
        conversationId: conversationId,
        conversationType: conversationType,
        ownerUid: ownerUid,
        ownerName: ownerName,
        startedAt: startedAt,
        state: CallRecordingState.recording,
        meetingId: meetingId,
        speakerUid: speakerUid,
        speakerName: speakerName,
      ).toMap(),
    );
    return doc.id;
  }

  Future<void> updateSession(
    String sessionId,
    Map<String, dynamic> fields,
  ) async {
    await _sessions.doc(sessionId).set(
      {
        ...fields,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<CallRecordingSession?> loadSession(String sessionId) async {
    final doc = await _sessions.doc(sessionId).get();
    if (!doc.exists) return null;
    return CallRecordingSession.fromDoc(doc);
  }

  /// Chunks for one recording, in recording order.
  Future<List<CallRecordingChunk>> loadChunks(String sessionId) async {
    final snapshot = await _chunks(sessionId).get();
    final chunks = snapshot.docs
        .map((doc) => CallRecordingChunk.fromMap(doc.id, doc.data()))
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return chunks;
  }

  Future<void> saveChunk(
    String sessionId,
    CallRecordingChunk chunk,
  ) async {
    await _chunks(sessionId).doc(chunk.chunkId).set(
          chunk.toMap(),
          SetOptions(merge: true),
        );
  }

  Future<void> updateChunk(
    String sessionId,
    String chunkId,
    Map<String, dynamic> fields,
  ) async {
    await _chunks(sessionId).doc(chunkId).set(
      {
        ...fields,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// The most recent recordings for a conversation, newest first.
  ///
  /// The query filters on [conversationId] only, so it needs no composite
  /// index; ordering and the type filter happen on the client.
  Future<List<CallRecordingSession>> sessionsForConversation({
    required String conversationId,
    required String conversationType,
    required String ownerUid,
    int limit = 10,
  }) async {
    if (conversationId.trim().isEmpty) return const [];

    final snapshot = await _sessions
        .where('conversationId', isEqualTo: conversationId.trim())
        .limit(limit)
        .get();

    // Only this device's owner can transcribe its own audio: another
    // participant's session has no local file here, and the Worker refuses a
    // media key that does not belong to the caller.
    final sessions = snapshot.docs
        .map(CallRecordingSession.fromDoc)
        .where((session) =>
            session.conversationType == conversationType &&
            session.ownerUid == ownerUid)
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    return sessions;
  }

  /// Every recording owned by one account, newest first.
  ///
  /// Used by the 24-hour audio sweep. The query filters on `ownerUid` only so
  /// it needs no composite index; the time comparison happens on the client.
  Future<List<CallRecordingSession>> sessionsForOwner(
    String ownerUid, {
    int limit = 60,
  }) async {
    if (ownerUid.trim().isEmpty) return const [];

    final snapshot = await _sessions
        .where('ownerUid', isEqualTo: ownerUid.trim())
        .limit(limit)
        .get();

    final sessions =
        snapshot.docs.map(CallRecordingSession.fromDoc).toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

    return sessions;
  }

  /// Reads the session back and confirms the transcript really is stored.
  ///
  /// Audio is deleted only when this returns true: the whole workflow depends
  /// on the saved transcript being the durable copy.
  Future<bool> verifyTranscriptSaved(
    String sessionId,
    String expectedTranscript,
  ) async {
    final expected = expectedTranscript.trim();
    if (expected.isEmpty) return false;

    final doc = await _sessions.doc(sessionId).get();
    if (!doc.exists) return false;

    final data = doc.data() ?? const <String, dynamic>{};
    final stored = (data['transcriptText'] ?? '').toString().trim();

    return stored.isNotEmpty &&
        stored == expected &&
        data['transcriptSavedAt'] is Timestamp;
  }
}
