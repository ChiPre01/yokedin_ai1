import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:yoked_in/ai/characters/calls/character_video_call_screen.dart';
import 'package:yoked_in/ai/characters/calls/character_voice_call_screen.dart';
import 'package:yoked_in/ai/characters/character_detail_screen.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/ai/characters/characters_screen.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_model.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_screen.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_service.dart';
import 'package:yoked_in/helper/navigation_helper.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

/// The signed-in user's active conversations with AI characters.
///
/// This serves as the 'Interaction' section of AI Universe, showing all
/// characters the user has started a conversation with, their last message,
/// and allowing one-tap resumption of any conversation.
class CharacterChatListScreen extends ConsumerWidget {
  const CharacterChatListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversationsAsync = ref.watch(conversationsProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Interactions',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            tooltip: 'All Characters',
            icon: const Icon(Icons.person_pin_circle_outlined),
            onPressed: () => NavigationHelper.push(
              context,
              const CharactersScreen(),
            ),
          ),
        ],
      ),
      body: conversationsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          onRetry: () => ref.invalidate(conversationsProvider),
        ),
        data: (conversations) {
          if (conversations.isEmpty) {
            return const _EmptyState();
          }

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(conversationsProvider),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: conversations.length,
              separatorBuilder: (context, index) => Divider(
                height: 1,
                indent: 82,
                endIndent: 16,
                color: Colors.grey.shade100,
              ),
              itemBuilder: (context, index) {
                final conversation = conversations[index];
                return _ConversationTile(conversation: conversation);
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.deepPurple.shade400,
        foregroundColor: Colors.white,
        onPressed: () => NavigationHelper.push(
          context,
          const CharactersScreen(),
        ),
        icon: const Icon(Icons.add_comment_outlined, size: 20),
        label: const Text('New Chat'),
      ),
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.conversation});

  final CharacterConversation conversation;

  String _formatTimestamp(DateTime? dateTime) {
    if (dateTime == null) return '';
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0 && dateTime.day == now.day) {
      return DateFormat('h:mm a').format(dateTime);
    } else if (difference.inDays == 1 ||
        (now.day - dateTime.day == 1 && difference.inDays < 2)) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return DateFormat('E').format(dateTime);
    } else {
      return DateFormat('MMM d').format(dateTime);
    }
  }

  Future<void> _showOptions(
    BuildContext context,
    WidgetRef ref,
    AiCharacter? character,
  ) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: Colors.white,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 4,
                width: 36,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.forum_outlined, color: Colors.deepPurple),
                title: const Text('Open Chat'),
                onTap: () => Navigator.pop(sheetContext, 'chat'),
              ),
              ListTile(
                leading: const Icon(Icons.call_outlined, color: Colors.green),
                title: const Text('Voice Call'),
                onTap: () => Navigator.pop(sheetContext, 'voice_call'),
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined, color: Colors.blue),
                title: const Text('Video Call'),
                onTap: () => Navigator.pop(sheetContext, 'video_call'),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline, color: Colors.black87),
                title: const Text('View Character Profile'),
                onTap: () => Navigator.pop(sheetContext, 'profile'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  'Delete Conversation',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );

    if (result == 'chat' && context.mounted) {
      NavigationHelper.push(
        context,
        CharacterChatScreen(characterId: conversation.characterId),
      );
    } else if (result == 'voice_call' && context.mounted) {
      NavigationHelper.push(
        context,
        CharacterVoiceCallScreen(characterId: conversation.characterId),
      );
    } else if (result == 'video_call' && context.mounted) {
      NavigationHelper.push(
        context,
        CharacterVideoCallScreen(characterId: conversation.characterId),
      );
    } else if (result == 'profile' && context.mounted) {
      NavigationHelper.push(
        context,
        CharacterDetailScreen(characterId: conversation.characterId),
      );
    } else if (result == 'delete' && context.mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete conversation?'),
          content: Text(
            'This will delete all message history with '
            '${character?.name ?? conversation.characterName}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
            ),
          ],
        ),
      );

      if (confirmed == true) {
        await ref
            .read(characterChatServiceProvider)
            .deleteConversation(conversation.id);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the live character profile to get updated portrait and details
    final characterAsync =
        ref.watch(characterStreamProvider(conversation.characterId));
    final character = characterAsync.asData?.value;

    final name = character?.name ?? conversation.characterName;
    final timeStr = _formatTimestamp(
      conversation.lastMessageAt ?? conversation.updatedAt,
    );

    final lastMessageText = conversation.lastMessage.trim().isNotEmpty
        ? (conversation.lastMessageRole == 'user'
            ? 'You: ${conversation.lastMessage}'
            : conversation.lastMessage)
        : 'Tap to start conversation';

    return InkWell(
      onTap: () => NavigationHelper.push(
        context,
        CharacterChatScreen(characterId: conversation.characterId),
      ),
      onLongPress: () => _showOptions(context, ref, character),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Character portrait avatar with sparkle indicator
            Stack(
              clipBehavior: Clip.none,
              children: [
                _CharacterAvatar(
                  character: character,
                  fallbackName: name,
                  size: 54,
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    height: 18,
                    width: 18,
                    decoration: BoxDecoration(
                      color: Colors.deepPurple.shade400,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: const Icon(
                      Icons.auto_awesome,
                      color: Colors.white,
                      size: 9,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),

            // Content: Name, Role chip, Last message
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                name.isEmpty ? 'Unnamed Character' : name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            if (character != null &&
                                character.role.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.deepPurple.shade50,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  CharacterRole.labelFor(character.role),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.deepPurple.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (timeStr.isNotEmpty)
                        Text(
                          timeStr,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade500,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lastMessageText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: conversation.lastMessage.isNotEmpty
                                ? Colors.grey.shade700
                                : Colors.deepPurple.shade400,
                            fontStyle: conversation.lastMessage.isEmpty
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ),
                      if (conversation.messageCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${conversation.messageCount}',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CharacterAvatar extends StatelessWidget {
  const _CharacterAvatar({
    required this.character,
    required this.fallbackName,
    required this.size,
  });

  final AiCharacter? character;
  final String fallbackName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final value = character;
    final initials = fallbackName.trim().isNotEmpty
        ? fallbackName.trim().substring(0, 1).toUpperCase()
        : 'AI';

    final fallback = CircleAvatar(
      radius: size / 2,
      backgroundColor: Colors.deepPurple.shade50,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.4,
          fontWeight: FontWeight.w600,
          color: Colors.deepPurple.shade400,
        ),
      ),
    );

    return ClipOval(
      child: SizedBox(
        height: size,
        width: size,
        child: value != null && value.hasPortrait
            ? CloudflareMediaImage(
                imageUrl: value.imageUrl,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
                error: fallback,
              )
            : fallback,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              height: 80,
              width: 80,
              decoration: BoxDecoration(
                color: Colors.deepPurple.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.forum_outlined,
                size: 38,
                color: Colors.deepPurple.shade400,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'No AI Conversations Yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Once you start chatting with an AI character, your conversations '
              'will appear here so you can pick them up anytime.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.deepPurple.shade400,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () => NavigationHelper.push(
                context,
                const CharactersScreen(),
              ),
              icon: const Icon(Icons.person_pin_circle_outlined, size: 20),
              label: const Text(
                'Explore Characters',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
            const SizedBox(height: 14),
            const Text(
              'Conversations could not be loaded',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Check your connection and try again.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
