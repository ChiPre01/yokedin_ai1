import 'package:cloud_firestore/cloud_firestore.dart';

/// How a character reply is produced and remembered.
///
/// One conversation per character, stored as `ai_conversations/{uid}_{id}`
/// with its messages in a subcollection. A separate collection keeps AI chats
/// out of the human chat list, which queries `chats` by participant.
class CharacterConversation {
  const CharacterConversation({
    required this.id,
    required this.ownerUid,
    required this.characterId,
    required this.characterName,
    required this.characterImageKey,
    required this.lastMessage,
    required this.lastMessageRole,
    required this.messageCount,
    required this.summarizedCount,
    required this.memorySummary,
    this.lastMessageAt,
    this.updatedAt,
  });

  final String id;
  final String ownerUid;
  final String characterId;
  final String characterName;
  final String characterImageKey;

  final String lastMessage;
  final String lastMessageRole; // 'user' | 'character'
  final int messageCount;

  /// How many of the oldest messages are already folded into [memorySummary].
  final int summarizedCount;

  final String memorySummary;

  final DateTime? lastMessageAt;
  final DateTime? updatedAt;

  /// Turns not yet folded into the summary.
  int get unsummarizedCount {
    final pending = messageCount - summarizedCount;
    return pending < 0 ? 0 : pending;
  }

  static DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  factory CharacterConversation.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};

    return CharacterConversation(
      id: doc.id,
      ownerUid: (data['ownerUid'] ?? '').toString(),
      characterId: (data['characterId'] ?? '').toString(),
      characterName: (data['characterName'] ?? '').toString(),
      characterImageKey: (data['characterImageKey'] ?? '').toString(),
      lastMessage: (data['lastMessage'] ?? '').toString(),
      lastMessageRole: (data['lastMessageRole'] ?? '').toString(),
      messageCount: (data['messageCount'] as num?)?.toInt() ?? 0,
      summarizedCount: (data['summarizedCount'] as num?)?.toInt() ?? 0,
      memorySummary: (data['memorySummary'] ?? '').toString(),
      lastMessageAt: _date(data['lastMessageAt']),
      updatedAt: _date(data['updatedAt']),
    );
  }
}

/// One stored chat message between the user and a character.
class CharacterChatMessage {
  const CharacterChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.createdAt,
  });

  final String id;

  /// 'user' or 'character'.
  final String role;
  final String text;
  final DateTime? createdAt;

  bool get isUser => role == 'user';

  static DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  factory CharacterChatMessage.fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? const <String, dynamic>{};

    return CharacterChatMessage(
      id: doc.id,
      role: (data['role'] ?? 'user').toString(),
      text: (data['text'] ?? '').toString(),
      createdAt: _date(data['createdAt']),
    );
  }

  /// The shape the Worker expects for history.
  Map<String, String> toPromptTurn() => {'role': role, 'text': text};
}
