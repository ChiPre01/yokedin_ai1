import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:yoked_in/ai/characters/character_ai_service.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

/// How the user wants to build the character: words alone, or words plus a
/// reference picture that the AI paints the portrait from.
enum _CreateMode { text, photo }

/// Describe a character, let the AI draft it, then give it a portrait.
///
/// The picture path uploads the chosen photo first: it is sent to the image
/// provider as a reference, so the generated portrait keeps that face instead
/// of inventing one. The character document is written before the portrait
/// exists, because the portrait and the reference are stored under keys that
/// contain the character id.
class CreateCharacterScreen extends ConsumerStatefulWidget {
  const CreateCharacterScreen({super.key});

  @override
  ConsumerState<CreateCharacterScreen> createState() =>
      _CreateCharacterScreenState();
}

class _CreateCharacterScreenState extends ConsumerState<CreateCharacterScreen> {
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();

  String _category = CharacterCategory.all.first.id;
  String _role = CharacterRole.all.first.id;

  _CreateMode _mode = _CreateMode.text;

  Map<String, dynamic>? _draft;
  String? _savedId;
  String? _characterDocId;
  String? _portraitUrl;
  String? _portraitKey;
  String? _error;
  String? _notice;

  Uint8List? _photoBytes;
  String? _photoKey;

  bool _drafting = false;
  bool _saving = false;
  bool _uploading = false;
  bool _generatingPortrait = false;

  @override
  void dispose() {
    // A picture uploaded but never used by a saved character would otherwise
    // stay in the bucket forever.
    final orphanKey = _photoKey;
    if (_savedId == null && orphanKey != null && orphanKey.isNotEmpty) {
      unawaited(
        CloudflareMediaService.instance
            .deleteMedia(orphanKey)
            .catchError((Object _) {}),
      );
    }

    _descriptionController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  bool get _hasDraft => _draft != null;

  bool get _isPhotoMode => _mode == _CreateMode.photo;

  /// Uploaded pictures that belong to this character, used for regeneration
  /// and removed along with it.
  List<String> get _referenceKeyList {
    final key = _photoKey;
    return (key == null || key.isEmpty) ? const [] : [key];
  }

  Future<void> _setMode(_CreateMode mode) async {
    if (mode == _mode) return;

    if (mode == _CreateMode.text) {
      await _removePhoto();
    }

    if (!mounted) return;
    setState(() {
      _mode = mode;
      _error = null;
      _notice = null;
    });
  }

  Future<void> _pickPhoto() async {
    setState(() {
      _error = null;
      _notice = null;
    });

    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1440,
        maxHeight: 1440,
        imageQuality: 85,
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      if (!mounted) return;

      setState(() {
        _photoBytes = bytes;
        _photoKey = null;
      });

      await _uploadPhoto(picked);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'That picture could not be opened. Please choose another.';
      });
    }
  }

  Future<void> _uploadPhoto(XFile file) async {
    setState(() => _uploading = true);

    try {
      final id = _characterDocId ??=
          ref.read(charactersServiceProvider).newCharacterId();

      final result = await CloudflareMediaService.instance.uploadFile(
        file,
        purpose: 'character',
        characterId: id,
      );

      final key = (result['key'] ?? '').toString();
      final url = (result['url'] ?? '').toString();
      if (key.isEmpty || url.isEmpty) {
        throw CloudflareMediaException('The upload was incomplete.');
      }

      if (!mounted) return;
      setState(() {
        _photoKey = key;
        _uploading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _photoKey = null;
        // The picture stays on screen so the user can retry or replace it,
        // and the server's own reason is shown instead of a vague failure.
        _error = error is CloudflareMediaException
            ? error.message
            : 'The picture could not be uploaded. Please try again.';
      });
    }
  }

  Future<void> _removePhoto() async {
    final key = _photoKey;
    if (key != null && key.isNotEmpty) {
      try {
        await CloudflareMediaService.instance.deleteMedia(key);
      } catch (error) {
        debugPrint('Character photo could not be deleted: $error');
      }
    }

    if (!mounted) return;
    setState(() {
      _photoBytes = null;
      _photoKey = null;
    });
  }

  Future<void> _createDraft() async {
    final description = _descriptionController.text.trim();

    if (_isPhotoMode) {
      if (_uploading) return;
      if ((_photoKey ?? '').isEmpty || _photoBytes == null) {
        setState(() => _error = 'Add a picture first.');
        return;
      }
      if (description.length < 12) {
        setState(() {
          _error = 'Describe what you want in a little more detail.';
        });
        return;
      }
    } else if (description.length < 12) {
      setState(() {
        _error = 'Describe the character in a little more detail first.';
      });
      return;
    }

    setState(() {
      _drafting = true;
      _error = null;
      _notice = null;
    });

    try {
      final result = await ref.read(characterAiServiceProvider).draftCharacter(
            description: description,
            category: _category,
            role: _role,
          );

      final character = result['character'];
      if (character is! Map) {
        throw const CharacterAiException(
          'The AI response was incomplete. Please try again.',
        );
      }

      final draft = Map<String, dynamic>.from(character);
      if (!mounted) return;
      setState(() {
        _draft = draft;
        _drafting = false;
        _nameController.text = _clean(draft['name']);
      });
    } on CharacterAiException catch (error) {
      if (!mounted) return;
      setState(() {
        _drafting = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _drafting = false;
        _error = 'The character could not be created. Please try again.';
      });
    }
  }

  Future<void> _generatePortrait() async {
    final draft = _draft;
    if (draft == null || _generatingPortrait) return;

    setState(() {
      _generatingPortrait = true;
      _error = null;
      _notice = null;
    });

    final fromPhoto = _isPhotoMode && (_photoKey ?? '').isNotEmpty;

    try {
      final id = _savedId ?? await _save();
      if (id == null) {
        throw const CharacterAiException(
          'The character could not be saved before generating its portrait.',
        );
      }

      final result = await ref.read(characterAiServiceProvider).generatePortrait(
            characterId: id,
            prompt: _portraitPrompt(draft, fromPhoto: fromPhoto),
            referenceKeys: fromPhoto ? _referenceKeyList : const [],
          );

      final url = (result['url'] ?? '').toString();
      final key = (result['key'] ?? '').toString();
      if (url.isEmpty) {
        throw const CharacterAiException(
          'The portrait came back without an address. Please try again.',
        );
      }

      await ref.read(charactersServiceProvider).updateCharacter(id, {
        'imageUrl': url,
        'imageKey': key,
        'portraitOrigin': fromPhoto ? 'generated-photo' : 'generated-text',
        'referenceKeys': _referenceKeyList,
      });

      if (!mounted) return;
      setState(() {
        _portraitUrl = url;
        _portraitKey = key;
        _generatingPortrait = false;
      });
    } on CharacterAiException catch (error) {
      if (!mounted) return;
      setState(() {
        _generatingPortrait = false;
        if (error.isNotConfigured) {
          // Keep the server's reason (it names the missing setting) instead of
          // hiding it behind generic copy.
          _notice = '${error.message} You can still save this character and '
              'try the portrait again later.';
        } else {
          _error = error.message;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generatingPortrait = false;
        _error = 'The portrait could not be generated. Please try again.';
      });
    }
  }

  Future<void> _saveFromButton() async {
    setState(() {
      _saving = true;
      _error = null;
    });

    final id = await _save();
    if (!mounted) return;

    setState(() {
      _saving = false;
    });

    if (id != null) {
      Navigator.pop(context);
    }
  }

  /// Writes (or updates) the character document. Returns its id.
  Future<String?> _save() async {
    final draft = _draft;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (draft == null || uid == null) return null;

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _error = 'Give the character a name before saving.';
      });
      return null;
    }

    if (_savedId != null) {
      await ref.read(charactersServiceProvider).updateCharacter(_savedId!, {
        'name': name,
        'category': _category,
        'role': _role,
        if ((_portraitUrl ?? '').isNotEmpty) ...{
          'imageUrl': _portraitUrl,
          'imageKey': _portraitKey ?? '',
        },
        'referenceKeys': _referenceKeyList,
      });
      return _savedId;
    }

    final character = AiCharacter(
      id: '',
      ownerUid: uid,
      name: name,
      category: _category,
      role: _role,
      description: _descriptionController.text.trim(),
      appearance: _clean(draft['appearance']),
      personality: _clean(draft['personality']),
      backstory: _clean(draft['backstory']),
      interests: _stringList(draft['interests']),
      speakingStyle: _clean(draft['speakingStyle']),
      language: _clean(draft['language'], fallback: 'English'),
      imagePrompt: _clean(draft['imagePrompt']),
      imageKey: _portraitKey ?? '',
      imageUrl: _portraitUrl ?? '',
      visibility: 'private',
      referenceKeys: _referenceKeyList,
      portraitOrigin: _isPhotoMode ? 'generated-photo' : 'generated-text',
    );

    final id = await ref
        .read(charactersServiceProvider)
        .addCharacter(character, id: _characterDocId);
    _savedId = id;
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final draft = _draft;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Create character',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _modeSelector(),
          const SizedBox(height: 16),
          if (!_isPhotoMode)
            Text(
              'Describe who you want to create. Appearance, personality, how '
              'they speak, anything that matters to you.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          if (_isPhotoMode) ..._photoSection(),
          const SizedBox(height: 12),
          TextField(
            controller: _descriptionController,
            minLines: 5,
            maxLines: 8,
            decoration: InputDecoration(
              hintText: _isPhotoMode
                  ? 'e.g. Make him a calm football coach in his 40s who speaks '
                      'slowly and teases gently.'
                  : 'e.g. A 25-year-old woman with braided hair, calm and '
                      'funny, speaks English with a warm voice, loves football.',
              hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _categoryField()),
              const SizedBox(width: 12),
              Expanded(child: _roleField()),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _drafting || _uploading ? null : _createDraft,
              icon: _drafting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_awesome, size: 18),
              label: Text(
                _drafting ? 'Creating your character…' : 'Create with AI',
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _Banner(message: _error!, isError: true),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 12),
            _Banner(message: _notice!, isError: false),
          ],
          if (draft != null) ...[
            const SizedBox(height: 22),
            const Divider(),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _portraitPreview(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${CharacterRole.labelFor(_role)} · '
                        '${CharacterCategory.labelFor(_category)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _readOnly('Appearance', _clean(draft['appearance'])),
            _readOnly('Personality', _clean(draft['personality'])),
            _readOnly('Backstory', _clean(draft['backstory'])),
            _readOnly('Speaking style', _clean(draft['speakingStyle'])),
            if (_stringList(draft['interests']).isNotEmpty)
              _readOnly('Interests', _stringList(draft['interests']).join(', ')),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _generatingPortrait ? null : _generatePortrait,
                    icon: _generatingPortrait
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.portrait_outlined, size: 18),
                    label: Text(
                      _generatingPortrait
                          ? 'Painting…'
                          : (_portraitUrl ?? '').isNotEmpty
                              ? 'New portrait'
                              : _isPhotoMode
                                  ? 'Generate portrait from photo'
                                  : 'Generate portrait',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _saveFromButton,
                child: Text(_saving ? 'Saving…' : 'Save character'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _modeSelector() {
    return Row(
      children: [
        Expanded(
          child: _modeTile(
            mode: _CreateMode.text,
            icon: Icons.notes,
            label: 'Describe with text',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _modeTile(
            mode: _CreateMode.photo,
            icon: Icons.add_photo_alternate_outlined,
            label: 'Add a picture',
          ),
        ),
      ],
    );
  }

  Widget _modeTile({
    required _CreateMode mode,
    required IconData icon,
    required String label,
  }) {
    final selected = _mode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _hasDraft ? null : () => _setMode(mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.deepPurple.shade50 : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? Colors.deepPurple.shade200 : Colors.grey.shade200,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 20,
              color: selected
                  ? Colors.deepPurple.shade300
                  : Colors.grey.shade500,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? Colors.deepPurple : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _photoSection() {
    return [
      const SizedBox(height: 4),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _photoFrame(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _photoBytes == null
                      ? 'Choose a picture of the person this character should '
                          'be.'
                      : _uploading
                          ? 'Uploading your picture…'
                          : 'Picture ready. It stays private to you.',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _hasDraft || _uploading ? null : _pickPhoto,
                      icon: const Icon(Icons.photo_library_outlined, size: 16),
                      label: Text(_photoBytes == null ? 'Choose' : 'Replace'),
                    ),
                    if (_photoBytes != null) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _hasDraft || _uploading ? null : _removePhoto,
                        child: const Text('Remove'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade50,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 18,
              color: Colors.deepPurple.shade300,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Your picture is used as a reference: AI paints a new portrait '
                'that keeps that face, guided by your words. The photo is '
                'stored privately and sent to the AI provider only to build '
                'this character.',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  color: Colors.deepPurple.shade400,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _photoFrame() {
    return Container(
      height: 96,
      width: 96,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: _photoBytes == null
          ? Icon(
              Icons.image_outlined,
              size: 36,
              color: Colors.grey.shade400,
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(_photoBytes!, fit: BoxFit.cover),
                if (_uploading)
                  Container(
                    color: Colors.black26,
                    child: const Center(
                      child: SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _portraitPreview() {
    final url = _portraitUrl ?? '';
    return Container(
      height: 96,
      width: 96,
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isEmpty
          ? Icon(
              Icons.person_outline,
              size: 40,
              color: Colors.deepPurple.shade200,
            )
          // Media is authenticated, so it must go through the same download
          // path as every other picture instead of Image.network.
          : CloudflareMediaImage(
              imageUrl: url,
              fit: BoxFit.cover,
              error: Icon(
                Icons.person_outline,
                size: 40,
                color: Colors.deepPurple.shade200,
              ),
            ),
    );
  }

  Widget _categoryField() {
    return DropdownButtonFormField<String>(
      initialValue: _category,
      decoration: const InputDecoration(
        labelText: 'Category',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: [
        for (final category in CharacterCategory.all)
          DropdownMenuItem(value: category.id, child: Text(category.label)),
      ],
      onChanged: _hasDraft
          ? null
          : (value) {
              if (value != null) setState(() => _category = value);
            },
    );
  }

  Widget _roleField() {
    return DropdownButtonFormField<String>(
      initialValue: _role,
      decoration: const InputDecoration(
        labelText: 'Role',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: [
        for (final role in CharacterRole.all)
          DropdownMenuItem(value: role.id, child: Text(role.label)),
      ],
      onChanged: _hasDraft
          ? null
          : (value) {
              if (value != null) setState(() => _role = value);
            },
    );
  }

  Widget _readOnly(String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 3),
          Text(value, style: const TextStyle(fontSize: 13.5, height: 1.35)),
        ],
      ),
    );
  }

  /// The stored description plus the look, so a regeneration keeps the face.
  String _portraitPrompt(Map<String, dynamic> draft, {bool fromPhoto = false}) {
    final parts = <String>[
      'Photorealistic portrait of ${_nameController.text.trim()}',
      if (fromPhoto)
        'Keep the face, features and likeness from the reference photo '
            'unchanged',
      _clean(draft['appearance']),
      _clean(draft['imagePrompt']),
      'natural lighting, sharp focus, looking at the camera, '
          'no text, no watermark',
    ].where((part) => part.trim().isNotEmpty);

    return parts.join('. ');
  }

  String _clean(Object? value, {String fallback = ''}) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? fallback : text;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? Colors.red : Colors.blue;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isError ? Colors.red.shade50 : Colors.blue.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
