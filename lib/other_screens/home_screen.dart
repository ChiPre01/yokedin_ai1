import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/screens/ai_universe_screen.dart';
import 'package:yoked_in/helper/navigation_helper.dart';
import 'package:yoked_in/other_screens/main_home.dart';
import 'package:yoked_in/other_screens/profile_screen.dart';
import 'package:yoked_in/provider/user_profile_provider.dart';
import 'package:yoked_in/widgets/user_avatar.dart';

/// First screen a signed-in user sees.
///
/// It is only a hub: each card opens one section of the app. The chat
/// experience itself (tabs, groups, connects) still lives in [MainHomeScreen],
/// which keeps its own bottom navigation. The profile moved here, so the hub
/// is also the place where the account and logout are reached.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayName = FirebaseAuth.instance.currentUser?.displayName?.trim();
    final firstName = (displayName == null || displayName.isEmpty)
        ? null
        : displayName.split(' ').first;
    final profile = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        const Text(
                          'Yoked In',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          firstName == null
                              ? 'What would you like to open?'
                              : 'Hi $firstName, what would you like to open?',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _ProfileShortcut(photoUrl: profile.photoUrl),
                ],
              ),
              const SizedBox(height: 28),
              _SectionCard(
                icon: Icons.chat_bubble_outline,
                title: 'Chat',
                subtitle: 'Messages, groups, calls and meeting minutes',
                accent: Colors.blue.shade600,
                onTap: () =>
                    NavigationHelper.push(context, const MainHomeScreen()),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                icon: Icons.auto_awesome,
                title: 'AI Universe',
                subtitle: 'Create AI characters, talk to them and make scenes',
                accent: Colors.deepPurple.shade400,
                badge: 'New',
                onTap: () =>
                    NavigationHelper.push(context, const AiUniverseScreen()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The avatar plus its caption in the top-right corner of the hub.
class _ProfileShortcut extends StatelessWidget {
  const _ProfileShortcut({required this.photoUrl});

  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => NavigationHelper.push(context, const ProfileScreen()),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          children: [
            UserAvatar(
              photoUrl: photoUrl,
              radius: 24,
              fallbackIcon: Icons.person,
              backgroundColor: Colors.grey.shade200,
            ),
            const SizedBox(height: 6),
            Text(
              'my profile',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.grey.shade50,
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
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accent, size: 28),
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
                        if (badge != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              badge!,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: accent,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
