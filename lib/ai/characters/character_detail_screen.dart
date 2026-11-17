import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/characters/character_ai_service.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

/// One character: its portrait, identity, and the actions that keep it alive
/// (regenerate the portrait, delete it).
///
/// Character chat lands here in the next phase; the entry point is deliberately
/// absent rather than a button that does nothing.
class CharacterDetailScreen extends ConsumerStatefulWidget {
  const CharacterDetailScreen({super.key, required this.characterId});

  final String characterId;

  @override
  ConsumerState<CharacterDetailScreen> createState() =>
      _CharacterDetailScreenState();
}

class _CharacterDetailScreenState extends ConsumerState<CharacterDetailScreen> {
  bool _regenerating = false;
  String? _error;

  Future<void> _regeneratePortrait(AiCharacter character) async {
    setState(() {
      _regenerating = true;
      _error = null;
    });

    try {
      final prompt = character.imagePrompt.trim().isNotEmpty
          ? character.imagePrompt.trim()
          : 'Photorealistic portrait of ${character.name}. '
              '${character.appearance}'.trim();

      // A character built from a photo keeps that face on every regeneration.
      final result = await ref
          .read(characterAiServiceProvider)
          .generatePortrait(
            characterId: character.id,
            prompt: prompt,
            referenceKeys: character.referenceKeys,
          );

      final url = (result['url'] ?? '').toString();
      final key = (result['key'] ?? '').toString();
      if (url.isEmpty) {
        throw const CharacterAiException(
          'The portrait came back without an address. Please try again.',
        );
      }

      await ref.read(charactersServiceProvider).updateCharacter(
        character.id,
        {
          'imageUrl': url,
          'imageKey': key,
          'portraitOrigin': character.hasReferencePhoto
              ? 'generated-photo'
              : 'generated-text',
        },
      );

      if (!mounted) return;
      setState(() => _regenerating = false);
    } on CharacterAiException catch (error) {
      if (!mounted) return;
      setState(() {
        _regenerating = false;
        _error = error.isNotConfigured
            ? '${error.message} Add the image provider key to the Worker '
                'secrets to generate portraits.'
            : error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _regenerating = false;
        _error = 'The portrait could not be regenerated. Please try again.';
      });
    }
  }

  Future<void> _delete(AiCharacter character) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete character'),
        content: Text(
          'Delete ${character.name.isEmpty ? 'this character' : character.name}? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Remove the stored portrait and any reference photos too, so deleting
      // a character does not leave unreachable images in the bucket. The
      // document is removed either way.
      final keys = <String>{
        if (character.imageKey.trim().isNotEmpty) character.imageKey.trim(),
        ...character.referenceKeys.where((key) => key.trim().isNotEmpty),
      };

      for (final key in keys) {
        try {
          await CloudflareMediaService.instance.deleteMedia(key);
        } catch (error) {
          debugPrint('Character media could not be deleted: $error');
        }
      }

      await ref
          .read(charactersServiceProvider)
          .deleteCharacter(character.id);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'The character could not be deleted.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final character = ref.watch(characterStreamProvider(widget.characterId));

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        title: Text(
          character.asData?.value?.name ?? 'Character',
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        actions: [
          if (character.asData?.value != null)
            IconButton(
              tooltip: 'Delete character',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(character.asData!.value!),
            ),
        ],
      ),
      body: character.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => const Center(
          child: Text('This character could not be loaded.'),
        ),
        data: (value) {
          if (value == null) {
            return const Center(child: Text('This character no longer exists.'));
          }
          return _body(value);
        },
      ),
    );
  }

  Widget _body(AiCharacter character) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              height: 220,
              width: 220,
              child: Container(
                color: Colors.grey.shade100,
                child: character.hasPortrait
                    ? CloudflareMediaImage(
                        imageUrl: character.imageUrl,
                        fit: BoxFit.cover,
                        cacheWidth: 720,
                        error: _initial(character),
                      )
                    : _initial(character),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            character.name.isEmpty ? 'Unnamed character' : character.name,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            '${CharacterRole.labelFor(character.role)} · '
            '${CharacterCategory.labelFor(character.category)}',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12.5, color: Colors.red),
            ),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _regenerating ? null : () => _regeneratePortrait(character),
            icon: _regenerating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, size: 18),
            label: Text(
              _regenerating
                  ? 'Painting a new portrait…'
                  : 'Regenerate portrait',
            ),
          ),
        ),
        const SizedBox(height: 20),
        _Section(title: 'Appearance', body: character.appearance),
        _Section(title: 'Personality', body: character.personality),
        _Section(title: 'Backstory', body: character.backstory),
        _Section(title: 'Speaking style', body: character.speakingStyle),
        if (character.interests.isNotEmpty)
          _Section(
            title: 'Interests',
            body: character.interests.join(', '),
          ),
      ],
    );
  }

  Widget _initial(AiCharacter character) {
    return Center(
      child: Container(
        height: 96,
        width: 96,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade50,
          shape: BoxShape.circle,
        ),
        child: Text(
          character.initial,
          style: TextStyle(
            fontSize: 38,
            fontWeight: FontWeight.w600,
            color: Colors.deepPurple.shade200,
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    if (body.trim().isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 3),
          Text(body, style: const TextStyle(fontSize: 13.5, height: 1.4)),
        ],
      ),
    );
  }
}
