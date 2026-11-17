import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/characters/character_model.dart';

final charactersServiceProvider = Provider<CharactersService>((ref) {
  return CharactersService();
});

/// The signed-in user's characters, newest first.
final charactersStreamProvider =
    StreamProvider<List<AiCharacter>>((ref) {
  return ref.watch(charactersServiceProvider).watchCharacters();
});

/// One character, kept live so an edit or a new portrait appears immediately.
final characterStreamProvider =
    StreamProvider.family<AiCharacter?, String>((ref, characterId) {
  return ref.watch(charactersServiceProvider).watchCharacter(characterId);
});

/// Firestore persistence for AI characters.
///
/// Mirrors the meeting-minutes service: owner-scoped collection, streaming
/// provider, and client-side sorting so no composite index is required.
class CharactersService {
  CharactersService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const String collectionName = 'ai_characters';

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _characters =>
      _firestore.collection(collectionName);

  Stream<List<AiCharacter>> watchCharacters() {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return Stream.value(const <AiCharacter>[]);

    return _characters.where('ownerUid', isEqualTo: uid).snapshots().map(
      (snapshot) {
        final characters =
            snapshot.docs.map(AiCharacter.fromDoc).toList()
              ..sort((a, b) {
                final aTime =
                    a.updatedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                final bTime =
                    b.updatedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
                return bTime.compareTo(aTime);
              });
        return characters;
      },
    );
  }

  Stream<AiCharacter?> watchCharacter(String characterId) {
    if (characterId.trim().isEmpty) return Stream.value(null);

    return _characters
        .doc(characterId.trim())
        .snapshots()
        .map((doc) => doc.exists ? AiCharacter.fromDoc(doc) : null);
  }

  /// An id for a character that has not been written yet.
  ///
  /// Reference photos upload to a path that contains the character id, so the
  /// id has to exist before the document does.
  String newCharacterId() => _characters.doc().id;

  Future<String> addCharacter(AiCharacter character, {String? id}) async {
    final doc = id == null ? _characters.doc() : _characters.doc(id);
    await doc.set(character.toMap());
    return doc.id;
  }

  Future<void> updateCharacter(
    String characterId,
    Map<String, dynamic> fields,
  ) async {
    await _characters.doc(characterId).set(
      {
        ...fields,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> deleteCharacter(String characterId) async {
    await _characters.doc(characterId).delete();
  }
}
