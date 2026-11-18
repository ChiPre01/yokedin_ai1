import 'package:flutter/material.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_list_screen.dart';
import 'package:yoked_in/ai/characters/characters_screen.dart';
import 'package:yoked_in/helper/navigation_helper.dart';

/// Entry point of the AI Universe section.
///
/// Characters and Interaction are active today; the other three pillars
/// are shown as the plan they are, in the order they will be built.
class AiUniverseScreen extends StatelessWidget {
  const AiUniverseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'AI Universe',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          const Text(
            'Create. Interact. Imagine. Produce.',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'A world where you build AI characters and use them for company, '
            'learning, entertainment and content creation.',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 22),
          _AvailableTile(
            icon: Icons.person_pin_circle_outlined,
            title: 'Characters',
            description:
                'Describe a character and AI builds them: a companion, a '
                'tutor, a musician. Keep the same face and personality.',
            onTap: () =>
                NavigationHelper.push(context, const CharactersScreen()),
          ),
          const SizedBox(height: 12),
          _AvailableTile(
            icon: Icons.forum_outlined,
            title: 'Interaction',
            description:
                'Chat with the AI characters you created. Pick up right '
                'where you left off.',
            onTap: () => NavigationHelper.push(
              context,
              const CharacterChatListScreen(),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Text(
                'Coming next',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Divider(color: Colors.grey.shade200)),
            ],
          ),
          const SizedBox(height: 14),
          const _PillarTile(
            icon: Icons.movie_creation_outlined,
            title: 'Studios',
            description:
                'Turn your characters into stories, dramas and short scenes, '
                'then download them to your device.',
          ),
          const SizedBox(height: 12),
          const _PillarTile(
            icon: Icons.content_cut,
            title: 'Creator Studio',
            description:
                'A CapCut-style editor for your own videos, rendered on your '
                'device and saved straight to your gallery or downloads.',
          ),
          const SizedBox(height: 12),
          const _PillarTile(
            icon: Icons.explore_outlined,
            title: 'Discover',
            description:
                'Browse and share characters with other creators in the '
                'community.',
          ),
        ],
      ),
    );
  }
}

class _AvailableTile extends StatelessWidget {
  const _AvailableTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.deepPurple.shade50,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                height: 54,
                width: 54,
                decoration: BoxDecoration(
                  color: Colors.deepPurple.shade100,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: Colors.deepPurple.shade400, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'Ready',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.deepPurple.shade400,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.3,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: Colors.deepPurple.shade200),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillarTile extends StatelessWidget {
  const _PillarTile({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.deepPurple.shade200, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
