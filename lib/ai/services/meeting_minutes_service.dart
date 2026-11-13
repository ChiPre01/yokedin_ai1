import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/models/meeting_minutes_model.dart';

final meetingMinutesServiceProvider = Provider<MeetingMinutesService>((ref) {
  return MeetingMinutesService();
});

final meetingMinutesStreamProvider =
    StreamProvider.family<List<MeetingMinutesModel>, String>((ref, conversationId) {
  final service = ref.watch(meetingMinutesServiceProvider);
  return service.getMeetingMinutesStream(conversationId);
});

class MeetingMinutesService {
  final FirebaseFirestore _firestore;

  MeetingMinutesService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _minutesCollection =>
      _firestore.collection('meeting_minutes');

  /// Streams meeting minutes for a specific conversation (chatId or groupId)
  Stream<List<MeetingMinutesModel>> getMeetingMinutesStream(String conversationId) {
    return _minutesCollection
        .where('conversationId', isEqualTo: conversationId)
        .snapshots()
        .map((snapshot) {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final list = snapshot.docs
          .map((doc) => MeetingMinutesModel.fromFirestore(doc))
          // Minutes are shared with everyone in the conversation. Removing
          // them only hides your own copy, so another participant's delete
          // never takes the minutes away from you.
          .where((minute) => uid.isEmpty || !minute.hiddenFor.contains(uid))
          .toList();
      // Sort in-memory to prevent requiring composite index creation during early testing
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return list;
    });
  }

  /// Fetches a single meeting minute by its document ID
  Future<MeetingMinutesModel?> getMeetingMinute(String minuteId) async {
    final doc = await _minutesCollection.doc(minuteId).get();
    if (!doc.exists) return null;
    return MeetingMinutesModel.fromFirestore(doc);
  }

  /// Adds a new meeting minute to Firestore
  Future<String> addMeetingMinute(MeetingMinutesModel minute) async {
    final docRef = await _minutesCollection.add(minute.toMap());
    return docRef.id;
  }

  /// Removes the minutes from the signed-in account only.
  ///
  /// The document stays in Firestore because every other participant of the
  /// meeting - and, for a group, every group member - keeps their own copy.
  Future<void> deleteMeetingMinute(String minuteId) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    await _minutesCollection.doc(minuteId).update({
      'hiddenFor': FieldValue.arrayUnion([uid]),
    });
  }

  /// Toggle action item completion status
  Future<void> toggleActionItem(
    String minuteId,
    int actionIndex,
    bool isCompleted,
  ) async {
    final doc = await _minutesCollection.doc(minuteId).get();
    if (!doc.exists) return;

    final data = doc.data()!;
    final actionItems = List<Map<String, dynamic>>.from(data['actionItems'] ?? []);
    if (actionIndex >= 0 && actionIndex < actionItems.length) {
      actionItems[actionIndex]['isCompleted'] = isCompleted;
      await _minutesCollection.doc(minuteId).update({'actionItems': actionItems});
    }
  }

  /// Creates a sample meeting minute for testing UI flows
  Future<String> createSampleMinute({
    required String conversationId,
    required String conversationType,
    required String conversationTitle,
    List<String> participants = const [],
    Map<String, String> participantNames = const {},
  }) async {
    final now = DateTime.now();
    final sample = MeetingMinutesModel(
      id: '',
      conversationId: conversationId,
      conversationType: conversationType,
      title: 'Call Sync with $conversationTitle',
      createdAt: now,
      durationSeconds: 420, // 7 minutes
      participants: participants,
      participantNames: participantNames,
      summary:
          'Discussion focused on project roadmap, upcoming feature rollouts, and task delegation for the week. Key milestones were agreed upon with upcoming deadlines.',
      keyDecisions: [
        'Approved Phase 1 design for AI meeting minutes integration.',
        'Agreed to prioritize free-tier AI APIs (Groq Whisper & Gemini Flash) to avoid unexpected subscription costs.',
        'Scheduled next sync for Friday at 10:00 AM.',
      ],
      actionItems: [
        ActionItemModel(
          task: 'Complete initial UI test on mobile and web',
          assignee: participantNames.values.isNotEmpty ? participantNames.values.first : 'User',
          dueDate: 'Tomorrow',
          isCompleted: false,
        ),
        ActionItemModel(
          task: 'Configure ZEGOCLOUD active noise suppression (ANS) in call settings',
          assignee: 'Dev Team',
          dueDate: 'By Friday',
          isCompleted: false,
        ),
        ActionItemModel(
          task: 'Review Firestore security rules for meeting_minutes collection',
          assignee: 'Security',
          dueDate: 'Next Monday',
          isCompleted: true,
        ),
      ],
      rawTranscript: [
        TranscriptSegmentModel(
          speaker: participantNames.values.isNotEmpty ? participantNames.values.first : 'Speaker 1',
          text: 'Hello, can you hear me clearly? Let us review the action items for the integration.',
          timestamp: '00:04',
        ),
        TranscriptSegmentModel(
          speaker: 'Speaker 2',
          text: 'Loud and clear. The noise filter is working well. Let us go through the plan.',
          timestamp: '00:12',
        ),
        TranscriptSegmentModel(
          speaker: participantNames.values.isNotEmpty ? participantNames.values.first : 'Speaker 1',
          text: 'Great, let us make sure all meeting summaries show up right in the chat more menu.',
          timestamp: '00:30',
        ),
      ],
    );

    return addMeetingMinute(sample);
  }
}
