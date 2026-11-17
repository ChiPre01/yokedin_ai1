import 'package:cloud_firestore/cloud_firestore.dart';

/// Categories a character can belong to. The stored value is the string in
/// [id], so documents stay readable if the list ever changes.
class CharacterCategory {
  const CharacterCategory(this.id, this.label);

  final String id;
  final String label;

  static const List<CharacterCategory> all = [
    CharacterCategory('human', 'Human'),
    CharacterCategory('animal', 'Animal'),
    CharacterCategory('mythical', 'Mythical'),
    CharacterCategory('legendary', 'Legendary'),
    CharacterCategory('object', 'Object'),
    CharacterCategory('fantasy', 'Fantasy'),
  ];

  static String labelFor(String id) {
    for (final category in all) {
      if (category.id == id) return category.label;
    }
    return id.isEmpty ? 'Character' : id;
  }
}

/// What a character is for. This drives the tone of its chat later on.
class CharacterRole {
  const CharacterRole(this.id, this.label);

  final String id;
  final String label;

  static const List<CharacterRole> all = [
    CharacterRole('companion', 'Companion'),
    CharacterRole('friend', 'Friend'),
    CharacterRole('tutor', 'Tutor'),
    CharacterRole('musician', 'Musician'),
    CharacterRole('storyteller', 'Storyteller'),
    CharacterRole('custom', 'Something else'),
  ];

  static String labelFor(String id) {
    for (final role in all) {
      if (role.id == id) return role.label;
    }
    return id.isEmpty ? 'Character' : id;
  }
}

/// A user-created AI character.
///
/// The identity lives here (and in Firestore) rather than in a model call, so
/// the same name, personality and portrait are reused every time the character
/// is opened, chatted with, or (later) put in a scene.
class AiCharacter {
  const AiCharacter({
    required this.id,
    required this.ownerUid,
    required this.name,
    required this.category,
    required this.role,
    required this.description,
    required this.appearance,
    required this.personality,
    required this.backstory,
    required this.interests,
    required this.speakingStyle,
    required this.language,
    required this.imagePrompt,
    required this.imageKey,
    required this.imageUrl,
    required this.visibility,
    this.referenceKeys = const [],
    this.portraitOrigin = 'generated-text',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String ownerUid;
  final String name;
  final String category;
  final String role;

  /// The original words the user typed, kept so the character can be redrafted
  /// without retyping everything.
  final String description;

  final String appearance;
  final String personality;
  final String backstory;
  final List<String> interests;
  final String speakingStyle;
  final String language;

  /// The prompt used for the portrait, stored so a regeneration keeps the same
  /// look instead of producing a different person.
  final String imagePrompt;

  final String imageKey;
  final String imageUrl;
  final String visibility; // 'private' | 'public'

  /// Uploaded photos the character was built from, kept so the portrait can be
  /// regenerated with the same face and so they can be deleted with it.
  final List<String> referenceKeys;

  /// How the portrait was made: 'generated-text', 'generated-photo' or
  /// 'uploaded' (the user's own picture, used unchanged).
  final String portraitOrigin;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get hasPortrait => imageUrl.trim().isNotEmpty;

  bool get hasReferencePhoto => referenceKeys.isNotEmpty;

  bool get usesUploadedPortrait => portraitOrigin == 'uploaded';

  String get initial {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
  }

  static DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    return null;
  }

  factory AiCharacter.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? const <String, dynamic>{};
    final rawInterests = data['interests'];
    final rawReferences = data['referenceKeys'];

    return AiCharacter(
      id: doc.id,
      ownerUid: (data['ownerUid'] ?? '').toString(),
      name: (data['name'] ?? '').toString(),
      category: (data['category'] ?? 'human').toString(),
      role: (data['role'] ?? 'companion').toString(),
      description: (data['description'] ?? '').toString(),
      appearance: (data['appearance'] ?? '').toString(),
      personality: (data['personality'] ?? '').toString(),
      backstory: (data['backstory'] ?? '').toString(),
      interests: rawInterests is List
          ? rawInterests
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList()
          : const [],
      speakingStyle: (data['speakingStyle'] ?? '').toString(),
      language: (data['language'] ?? 'English').toString(),
      imagePrompt: (data['imagePrompt'] ?? '').toString(),
      imageKey: (data['imageKey'] ?? '').toString(),
      imageUrl: (data['imageUrl'] ?? '').toString(),
      visibility: (data['visibility'] ?? 'private').toString(),
      referenceKeys: rawReferences is List
          ? rawReferences
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList()
          : const [],
      portraitOrigin: (data['portraitOrigin'] ?? 'generated-text').toString(),
      createdAt: _date(data['createdAt']),
      updatedAt: _date(data['updatedAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'ownerUid': ownerUid,
      'name': name,
      'category': category,
      'role': role,
      'description': description,
      'appearance': appearance,
      'personality': personality,
      'backstory': backstory,
      'interests': interests,
      'speakingStyle': speakingStyle,
      'language': language,
      'imagePrompt': imagePrompt,
      'imageKey': imageKey,
      'imageUrl': imageUrl,
      'visibility': visibility,
      'referenceKeys': referenceKeys,
      'portraitOrigin': portraitOrigin,
      'createdAt': createdAt == null
          ? FieldValue.serverTimestamp()
          : Timestamp.fromDate(createdAt!),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  AiCharacter copyWith({
    String? name,
    String? category,
    String? role,
    String? description,
    String? appearance,
    String? personality,
    String? backstory,
    List<String>? interests,
    String? speakingStyle,
    String? language,
    String? imagePrompt,
    String? imageKey,
    String? imageUrl,
    String? visibility,
    List<String>? referenceKeys,
    String? portraitOrigin,
  }) {
    return AiCharacter(
      id: id,
      ownerUid: ownerUid,
      name: name ?? this.name,
      category: category ?? this.category,
      role: role ?? this.role,
      description: description ?? this.description,
      appearance: appearance ?? this.appearance,
      personality: personality ?? this.personality,
      backstory: backstory ?? this.backstory,
      interests: interests ?? this.interests,
      speakingStyle: speakingStyle ?? this.speakingStyle,
      language: language ?? this.language,
      imagePrompt: imagePrompt ?? this.imagePrompt,
      imageKey: imageKey ?? this.imageKey,
      imageUrl: imageUrl ?? this.imageUrl,
      visibility: visibility ?? this.visibility,
      referenceKeys: referenceKeys ?? this.referenceKeys,
      portraitOrigin: portraitOrigin ?? this.portraitOrigin,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}
