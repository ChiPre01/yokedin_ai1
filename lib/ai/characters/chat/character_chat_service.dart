import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_model.dart';

final characterChatServiceProvider = Provider<CharacterChatService>((ref) {
  return CharacterChatService();
});

/// The signed-in user's character conversations, newest activity first.
final conversationsProvider =
    StreamProvider<List<CharacterConversation>>((ref) {
  return ref.watch(characterChatServiceProvider).watchConversations();
});

/// One conversation, kept live so memory updates appear immediately.
final conversationProvider =
    StreamProvider.family<CharacterConversation?, String>((ref, id) {
  return ref.watch(characterChatServiceProvider).watchConversation(id);
});

/// The newest page of a conversation's messages, newest first.
final chatMessagesProvider =
    StreamProvider.family<List<CharacterChatMessage>, String>((ref, id) {
  return ref.watch(characterChatServiceProvider).watchMessages(id);
});

/// Firestore persistence for character chat.
///
/// Layout:
///   ai_conversations/{uid}_{characterId}
///   ai_conversations/{uid}_{characterId}/messages/{messageId}
///
/// The deterministic id enforces one conversation per character without a
/// lookup, and the subcollection keeps these messages out of the human
/// `messages`/`chats` collections.
class CharacterChatService {
  CharacterChatService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const String collectionName = 'ai_conversations';
  static const String messagesCollectionName = 'messages';

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _conversations =>
      _firestore.collection(collectionName);

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  String conversationIdFor(String characterId) => '${_uid}_$characterId';

  CollectionReference<Map<String, dynamic>> _messagesOf(String conversationId) =>
      _conversations.doc(conversationId).collection(messagesCollectionName);

  /// Returns the conversation id, creating the document on first use.
  Future<String> ensureConversation({
    required String characterId,
    required String characterName,
    String characterImageKey = '',
  }) async {
    final uid = _uid;
    if (uid.isEmpty) {
      throw StateError('Please sign in again to chat with your characters.');
    }

    final id = conversationIdFor(characterId);
    final doc = _conversations.doc(id);
    final snapshot = await doc.get();
    if (snapshot.exists) return id;

    await doc.set({
      'ownerUid': uid,
      'characterId': characterId,
      'characterName': characterName,
      'characterImageKey': characterImageKey,
      'lastMessage': '',
      'lastMessageRole': '',
      'lastMessageAt': FieldValue.serverTimestamp(),
      'messageCount': 0,
      'summarizedCount': 0,
      'memorySummary': '',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    return id;
  }

  Stream<List<CharacterConversation>> watchConversations() {
    final uid = _uid;
    if (uid.isEmpty) return Stream.value(const <CharacterConversation>[]);

    return _conversations
        .where('ownerUid', isEqualTo: uid)
        .snapshots()
        .map((snapshot) {
      final conversations =
          snapshot.docs.map(CharacterConversation.fromDoc).toList()
            ..sort((a, b) {
              final aTime = a.lastMessageAt ??
                  a.updatedAt ??
                  DateTime.fromMillisecondsSinceEpoch(0);
              final bTime = b.lastMessageAt ??
                  b.updatedAt ??
                  DateTime.fromMillisecondsSinceEpoch(0);
              return bTime.compareTo(aTime);
            });
      return conversations;
    });
  }

  Stream<CharacterConversation?> watchConversation(String conversationId) {
    if (conversationId.trim().isEmpty) return Stream.value(null);

    return _conversations
        .doc(conversationId.trim())
        .snapshots()
        .map((doc) => doc.exists ? CharacterConversation.fromDoc(doc) : null);
  }

  Stream<List<CharacterChatMessage>> watchMessages(String conversationId) {
    if (conversationId.trim().isEmpty) {
      return Stream.value(const <CharacterChatMessage>[]);
    }

    // A single field plus a limit needs no composite index.
    return _messagesOf(conversationId.trim())
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots()
        .map((snapshot) =>
            snapshot.docs.map(CharacterChatMessage.fromDoc).toList());
  }

  Future<CharacterConversation?> getConversation(String conversationId) async {
    final doc = await _conversations.doc(conversationId).get();
    if (!doc.exists) return null;
    return CharacterConversation.fromDoc(doc);
  }

  Future<void> addUserMessage({
    required String conversationId,
    required String text,
  }) {
    return _addMessage(
      conversationId: conversationId,
      role: 'user',
      text: text,
    );
  }

  Future<void> addCharacterMessage({
    required String conversationId,
    required String text,
  }) {
    return _addMessage(
      conversationId: conversationId,
      role: 'character',
      text: text,
    );
  }

  Future<void> _addMessage({
    required String conversationId,
    required String role,
    required String text,
  }) async {
    final batch = _firestore.batch();

    batch.set(_messagesOf(conversationId).doc(), {
      'ownerUid': _uid,
      'role': role,
      'text': text,
      'createdAt': FieldValue.serverTimestamp(),
    });

    batch.set(
      _conversations.doc(conversationId),
      {
        'lastMessage': text,
        'lastMessageRole': role,
        'lastMessageAt': FieldValue.serverTimestamp(),
        'messageCount': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );

    await batch.commit();
  }

  /// The most recent turns, oldest first, in the shape the Worker expects.
  Future<List<Map<String, String>>> recentMessages(
    String conversationId, {
    int limit = 20,
  }) async {
    final snapshot = await _messagesOf(conversationId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();

    return snapshot.docs.reversed
        .map(CharacterChatMessage.fromDoc)
        .where((message) => message.text.trim().isNotEmpty)
        .map((message) => message.toPromptTurn())
        .toList();
  }

  /// Older turns that have not been folded into the summary yet, oldest first.
  Future<List<Map<String, String>>> messagesForMemory(
    String conversationId, {
    required int skip,
    int limit = 20,
  }) async {
    final offset = skip < 0 ? 0 : skip;

    // cloud_firestore 6 removed Query.skip, so the page is read from the
    // beginning and the already-summarised turns are dropped here.
    final snapshot = await _messagesOf(conversationId)
        .orderBy('createdAt')
        .limit(offset + limit)
        .get();

    return snapshot.docs
        .skip(offset)
        .map(CharacterChatMessage.fromDoc)
        .where((message) => message.text.trim().isNotEmpty)
        .map((message) => message.toPromptTurn())
        .toList();
  }

  Future<void> setMemory(
    String conversationId, {
    required String summary,
    required int summarizedCount,
  }) async {
    await _conversations.doc(conversationId).set(
      {
        'memorySummary': summary,
        'summarizedCount': summarizedCount,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  /// Removes every message and clears the memory, keeping the conversation.
  Future<void> clearHistory(String conversationId) async {
    await _deleteMessages(conversationId);
    await _conversations.doc(conversationId).set(
      {
        'lastMessage': '',
        'lastMessageRole': '',
        'messageCount': 0,
        'summarizedCount': 0,
        'memorySummary': '',
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> deleteConversation(String conversationId) async {
    await _deleteMessages(conversationId);
    await _conversations.doc(conversationId).delete();
  }

  /// Deletes the conversation belonging to a character, used when the
  /// character itself is removed. Failures are logged, not thrown, so deleting
  /// the character is never blocked by a leftover message.
  ///
  /// The id is deterministic, so this needs no query (and therefore no
  /// composite index on `ownerUid` + `characterId`).
  Future<void> deleteForCharacter(String characterId) async {
    if (_uid.isEmpty) return;

    final id = conversationIdFor(characterId);

    try {
      final doc = await _conversations.doc(id).get();
      if (doc.exists) await deleteConversation(id);
    } catch (error) {
      debugPrint('Character conversation could not be deleted: $error');
    }
  }

  Future<void> _deleteMessages(String conversationId) async {
    final snapshot = await _messagesOf(conversationId).get();

    // Firestore caps a batch at 500 writes.
    for (var start = 0; start < snapshot.docs.length; start += 400) {
      final batch = _firestore.batch();
      final end = (start + 400).clamp(0, snapshot.docs.length);
      for (final doc in snapshot.docs.sublist(start, end)) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
  }
}
