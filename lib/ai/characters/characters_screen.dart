import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/ai/characters/character_detail_screen.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_list_screen.dart';
import 'package:yoked_in/ai/characters/create_character_screen.dart';
import 'package:yoked_in/helper/navigation_helper.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

/// The signed-in user's AI characters.
class CharactersScreen extends ConsumerWidget {
  const CharactersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final characters = ref.watch(charactersStreamProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'AI Characters',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            tooltip: 'Conversations',
            icon: const Icon(Icons.forum_outlined),
            onPressed: () => NavigationHelper.push(
              context,
              const CharacterChatListScreen(),
            ),
          ),
        ],
      ),
      body: characters.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _Message(
          icon: Icons.error_outline,
          title: 'Characters could not be loaded',
          body: 'Check your connection and pull the screen to try again.',
          actionLabel: 'Retry',
          onAction: () => ref.invalidate(charactersStreamProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return _Message(
              icon: Icons.auto_awesome_outlined,
              title: 'No characters yet',
              body: 'Describe who you want to meet and AI will build them for '
                  'you: a companion, a tutor, a musician, anyone.',
              actionLabel: 'Create a character',
              onAction: () => NavigationHelper.push(
                context,
                const CreateCharacterScreen(),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(charactersStreamProvider),
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.78,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) => _CharacterCard(
                character: items[index],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => NavigationHelper.push(
          context,
          const CreateCharacterScreen(),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
    );
  }
}

class _CharacterCard extends StatelessWidget {
  const _CharacterCard({required this.character});

  final AiCharacter character;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => NavigationHelper.push(
        context,
        CharacterDetailScreen(characterId: character.id),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: double.infinity,
                color: Colors.grey.shade100,
                child: character.hasPortrait
                    ? CloudflareMediaImage(
                        imageUrl: character.imageUrl,
                        fit: BoxFit.cover,
                        error: _Initials(character: character, size: 40),
                      )
                    : _Initials(character: character, size: 40),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            character.name.isEmpty ? 'Unnamed character' : character.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${CharacterRole.labelFor(character.role)} · '
            '${CharacterCategory.labelFor(character.category)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.character, required this.size});

  final AiCharacter character;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        height: size * 2,
        width: size * 2,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade50,
          shape: BoxShape.circle,
        ),
        child: Text(
          character.initial,
          style: TextStyle(
            fontSize: size * 0.8,
            fontWeight: FontWeight.w600,
            color: Colors.deepPurple.shade200,
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 46, color: Colors.deepPurple.shade100),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 18),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
