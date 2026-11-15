import 'package:flutter/material.dart';

/// Entry point of the AI Universe section.
///
/// The section is still being built, so this screen only lays out where it is
/// going: the five parts that will grow here, in the order they get built.
class AiUniverseScreen extends StatelessWidget {
  const AiUniverseScreen({super.key});

  static const List<_Pillar> _pillars = [
    _Pillar(
      icon: Icons.person_pin_circle_outlined,
      title: 'Characters',
      description:
          'Create a character from text, pictures or both, and keep the same '
          'face, voice and personality every time you use it.',
    ),
    _Pillar(
      icon: Icons.forum_outlined,
      title: 'Interaction',
      description:
          'Chat, voice calls and live video with the characters you created.',
    ),
    _Pillar(
      icon: Icons.movie_creation_outlined,
      title: 'Studios',
      description:
          'Turn your characters into stories, dramas and short scenes, then '
          'download them to your device.',
    ),
    _Pillar(
      icon: Icons.content_cut,
      title: 'Creator Studio',
      description:
          'A CapCut-style editor for your own videos, rendered on your device '
          'and saved straight to your gallery or downloads.',
    ),
    _Pillar(
      icon: Icons.explore_outlined,
      title: 'Discover',
      description:
          'Browse and share characters with other creators in the community.',
    ),
  ];

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
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.deepPurple.shade50,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.construction_outlined,
                  size: 18,
                  color: Colors.deepPurple.shade300,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This section is in development. Character creation comes '
                    'first.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.deepPurple.shade300,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          for (final pillar in _pillars) ...[
            _PillarTile(pillar: pillar),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _Pillar {
  const _Pillar({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}

class _PillarTile extends StatelessWidget {
  const _PillarTile({required this.pillar});

  final _Pillar pillar;

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
          Icon(pillar.icon, color: Colors.deepPurple.shade200, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pillar.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  pillar.description,
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
