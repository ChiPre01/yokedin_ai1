import 'package:cloud_firestore/cloud_firestore.dart';

class ActionItemModel {
  final String task;
  final String? assignee;
  final String? dueDate;
  final bool isCompleted;

  ActionItemModel({
    required this.task,
    this.assignee,
    this.dueDate,
    this.isCompleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'task': task,
      'assignee': assignee,
      'dueDate': dueDate,
      'isCompleted': isCompleted,
    };
  }

  factory ActionItemModel.fromMap(Map<String, dynamic> map) {
    return ActionItemModel(
      task: map['task'] as String? ?? '',
      assignee: map['assignee'] as String?,
      dueDate: map['dueDate'] as String?,
      isCompleted: map['isCompleted'] as bool? ?? false,
    );
  }

  ActionItemModel copyWith({
    String? task,
    String? assignee,
    String? dueDate,
    bool? isCompleted,
  }) {
    return ActionItemModel(
      task: task ?? this.task,
      assignee: assignee ?? this.assignee,
      dueDate: dueDate ?? this.dueDate,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }
}

class TranscriptSegmentModel {
  final String speaker;
  final String text;
  final String timestamp;

  TranscriptSegmentModel({
    required this.speaker,
    required this.text,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'speaker': speaker,
      'text': text,
      'timestamp': timestamp,
    };
  }

  factory TranscriptSegmentModel.fromMap(Map<String, dynamic> map) {
    return TranscriptSegmentModel(
      speaker: map['speaker'] as String? ?? 'Speaker',
      text: map['text'] as String? ?? '',
      timestamp: map['timestamp'] as String? ?? '00:00',
    );
  }
}

class MeetingMinutesModel {
  final String id;
  final String conversationId; // chatId or groupId
  final String conversationType; // 'private' or 'group'
  final String title;
  final DateTime createdAt;
  final int durationSeconds;
  final List<String> participants;
  final Map<String, String> participantNames;
  final String summary;
  final List<String> keyDecisions;
  final List<ActionItemModel> actionItems;
  final List<TranscriptSegmentModel> rawTranscript;

  /// The shared meeting recording these minutes were built from, when they
  /// came from a call rather than pasted notes.
  final String? meetingId;

  /// Accounts that removed these minutes from their own list. Deleting is
  /// per-account so one participant's action never removes another's copy.
  final List<String> hiddenFor;

  MeetingMinutesModel({
    required this.id,
    required this.conversationId,
    required this.conversationType,
    required this.title,
    required this.createdAt,
    this.durationSeconds = 0,
    this.participants = const [],
    this.participantNames = const {},
    required this.summary,
    this.keyDecisions = const [],
    this.actionItems = const [],
    this.rawTranscript = const [],
    this.meetingId,
    this.hiddenFor = const [],
  });

  Map<String, dynamic> toMap() {
    return {
      'conversationId': conversationId,
      'conversationType': conversationType,
      'title': title,
      'createdAt': Timestamp.fromDate(createdAt),
      'durationSeconds': durationSeconds,
      'participants': participants,
      'participantNames': participantNames,
      'summary': summary,
      'keyDecisions': keyDecisions,
      'actionItems': actionItems.map((item) => item.toMap()).toList(),
      'rawTranscript': rawTranscript.map((segment) => segment.toMap()).toList(),
      'meetingId': meetingId,
      'hiddenFor': hiddenFor,
    };
  }

  factory MeetingMinutesModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return MeetingMinutesModel.fromMap(data, doc.id);
  }

  factory MeetingMinutesModel.fromMap(Map<String, dynamic> map, String docId) {
    DateTime parsedDate;
    final createdAtRaw = map['createdAt'];
    if (createdAtRaw is Timestamp) {
      parsedDate = createdAtRaw.toDate();
    } else if (createdAtRaw is int) {
      parsedDate = DateTime.fromMillisecondsSinceEpoch(createdAtRaw);
    } else {
      parsedDate = DateTime.now();
    }

    final actionItemsList = (map['actionItems'] as List<dynamic>?)
            ?.map((e) => ActionItemModel.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList() ??
        [];

    final transcriptList = (map['rawTranscript'] as List<dynamic>?)
            ?.map((e) => TranscriptSegmentModel.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList() ??
        [];

    final decisionsList = (map['keyDecisions'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    final participantsList = (map['participants'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    final namesMap = (map['participantNames'] as Map<dynamic, dynamic>?)
            ?.map((key, value) => MapEntry(key.toString(), value.toString())) ??
        {};

    final hiddenForList = (map['hiddenFor'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [];

    return MeetingMinutesModel(
      id: docId,
      conversationId: map['conversationId'] as String? ?? '',
      conversationType: map['conversationType'] as String? ?? 'private',
      title: map['title'] as String? ?? 'Meeting Minutes',
      createdAt: parsedDate,
      durationSeconds: (map['durationSeconds'] as num?)?.toInt() ?? 0,
      participants: participantsList,
      participantNames: namesMap,
      summary: map['summary'] as String? ?? '',
      keyDecisions: decisionsList,
      actionItems: actionItemsList,
      rawTranscript: transcriptList,
      meetingId: map['meetingId']?.toString(),
      hiddenFor: hiddenForList,
    );
  }

  String get formattedDuration {
    if (durationSeconds <= 0) return '';
    final minutes = durationSeconds ~/ 60;
    final seconds = durationSeconds % 60;
    if (minutes == 0) return '${seconds}s';
    return '${minutes}m ${seconds}s';
  }
}
