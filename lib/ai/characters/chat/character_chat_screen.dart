import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:yoked_in/ai/characters/calls/character_video_call_screen.dart';
import 'package:yoked_in/ai/characters/calls/character_voice_call_screen.dart';
import 'package:yoked_in/ai/characters/character_ai_service.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_model.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_service.dart';
import 'package:yoked_in/ai/config/ai_config.dart';
import 'package:yoked_in/helper/navigation_helper.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

/// Chat with one character.
///
/// One conversation per character, stored by [CharacterChatService]. Replies
/// are produced by the Worker, which reads the character profile itself; this
/// screen only supplies the recent turns and the stored memory summary.
class CharacterChatScreen extends ConsumerStatefulWidget {
  const CharacterChatScreen({super.key, required this.characterId});

  final String characterId;

  @override
  ConsumerState<CharacterChatScreen> createState() =>
      _CharacterChatScreenState();
}

class _CharacterChatScreenState extends ConsumerState<CharacterChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String? _conversationId;
  bool _opening = true;
  bool _awaiting = false;
  bool _summarizing = false;
  bool _dailyLimit = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_openConversation());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _openConversation() async {
    try {
      // First snapshot only: the conversation needs the name and portrait
      // once, at creation; the screen keeps watching the character after that.
      final character = await ref
          .read(charactersServiceProvider)
          .watchCharacter(widget.characterId)
          .first;

      if (character == null) {
        if (!mounted) return;
        setState(() {
          _opening = false;
          _error = 'This character no longer exists.';
        });
        return;
      }

      final id = await ref.read(characterChatServiceProvider).ensureConversation(
            characterId: widget.characterId,
            characterName: character.name,
            characterImageKey: character.imageKey,
          );

      if (!mounted) return;
      setState(() {
        _conversationId = id;
        _opening = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'This conversation could not be opened. Please try again.';
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final conversationId = _conversationId;
    if (text.isEmpty || conversationId == null || _awaiting || _dailyLimit) {
      return;
    }

    _input.clear();
    setState(() {
      _awaiting = true;
      _error = null;
    });

    final service = ref.read(characterChatServiceProvider);

    try {
      await service.addUserMessage(
        conversationId: conversationId,
        text: text,
      );
      await _requestReply(conversationId);
    } on CharacterAiException catch (error) {
      if (!mounted) return;
      setState(() {
        _awaiting = false;
        _error = error.message;
        _dailyLimit = error.isDailyLimit;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _awaiting = false;
        _error = 'The message could not be sent. Please try again.';
      });
    }
  }

  /// Asks for a reply to whatever is already stored, without adding a message.
  Future<void> _retryReply() async {
    final conversationId = _conversationId;
    if (conversationId == null || _awaiting) return;

    setState(() {
      _awaiting = true;
      _error = null;
    });

    try {
      await _requestReply(conversationId);
    } on CharacterAiException catch (error) {
      if (!mounted) return;
      setState(() {
        _awaiting = false;
        _error = error.message;
        _dailyLimit = error.isDailyLimit;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _awaiting = false;
        _error = 'The character could not reply. Please try again.';
      });
    }
  }

  Future<void> _requestReply(String conversationId) async {
    final service = ref.read(characterChatServiceProvider);
    final conversation = await service.getConversation(conversationId);
    final history = await service.recentMessages(
      conversationId,
      limit: AIConfig.characterChatHistoryLimit,
    );

    final reply = await ref.read(characterAiServiceProvider).sendCharacterMessage(
          characterId: widget.characterId,
          recentMessages: history,
          memory: conversation?.memorySummary ?? '',
        );

    await service.addCharacterMessage(
      conversationId: conversationId,
      text: reply,
    );

    if (!mounted) return;
    setState(() {
      _awaiting = false;
      _error = null;
    });

    unawaited(_maybeSummarize(conversationId));
  }

  /// Folds the oldest unsummarised turns into the stored memory once enough
  /// have piled up, so prompt cost stays flat instead of growing forever.
  Future<void> _maybeSummarize(String conversationId) async {
    if (_summarizing) return;
    _summarizing = true;

    try {
      final service = ref.read(characterChatServiceProvider);
      final conversation = await service.getConversation(conversationId);
      if (conversation == null) return;

      final pending = conversation.unsummarizedCount;
      if (pending < AIConfig.characterMemoryBatchSize) return;

      final batch = await service.messagesForMemory(
        conversationId,
        skip: conversation.summarizedCount,
        limit: AIConfig.characterMemoryBatchSize,
      );
      if (batch.isEmpty) return;

      final summary =
          await ref.read(characterAiServiceProvider).summarizeCharacterMemory(
                characterId: widget.characterId,
                messages: batch,
                memory: conversation.memorySummary,
              );
      if (summary.isEmpty) return;

      await service.setMemory(
        conversationId,
        summary: summary,
        summarizedCount: conversation.summarizedCount + batch.length,
      );
    } catch (error) {
      // Memory is an optimisation: a failure must never break the chat.
      debugPrint('Character memory update failed: $error');
    } finally {
      _summarizing = false;
    }
  }

  Future<void> _clearHistory() async {
    final conversationId = _conversationId;
    if (conversationId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear conversation'),
        content: const Text(
          'This deletes every message and what the character remembers about '
          'you. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref
          .read(characterChatServiceProvider)
          .clearHistory(conversationId);
      if (!mounted) return;
      setState(() => _error = null);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'The conversation could not be cleared.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final character = ref.watch(characterStreamProvider(widget.characterId));
    final value = character.asData?.value;
    final conversationId = _conversationId;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        titleSpacing: 0,
        title: Row(
          children: [
            _Avatar(character: value, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                value?.name ?? 'Character',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Voice Call',
            icon: const Icon(Icons.call_outlined, color: Colors.black87),
            onPressed: () => NavigationHelper.push(
              context,
              CharacterVoiceCallScreen(characterId: widget.characterId),
            ),
          ),
          IconButton(
            tooltip: 'Video Call',
            icon: const Icon(Icons.videocam_outlined, color: Colors.black87),
            onPressed: () => NavigationHelper.push(
              context,
              CharacterVideoCallScreen(characterId: widget.characterId),
            ),
          ),
          if (conversationId != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.black87),
              onSelected: (choice) {
                if (choice == 'clear') _clearHistory();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'clear',
                  child: Text('Clear conversation'),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _opening
                ? const Center(child: CircularProgressIndicator())
                : conversationId == null
                    ? Center(
                        child: Text(
                          _error ?? 'This conversation is not available.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : _MessageList(
                        conversationId: conversationId,
                        character: value,
                        awaiting: _awaiting,
                        scrollController: _scroll,
                      ),
          ),
          if (_error != null && conversationId != null) _errorBanner(),
          _composer(),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 18, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(fontSize: 12.5, color: Colors.red),
            ),
          ),
          if (!_dailyLimit)
            TextButton(
              onPressed: _awaiting ? null : _retryReply,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
              ),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  Widget _composer() {
    final enabled = !_opening &&
        _conversationId != null &&
        !_awaiting &&
        !_dailyLimit;

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withValues(alpha: 0.2),
            spreadRadius: 1,
            blurRadius: 3,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: _dailyLimit
                    ? "Today's message limit reached"
                    : 'Message your character…',
                hintStyle: TextStyle(fontSize: 13.5, color: Colors.grey.shade400),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey.shade100,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            height: 42,
            width: 42,
            child: _awaiting
                ? const Center(
                    child: SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    onPressed: enabled ? _send : null,
                    icon: Icon(
                      Icons.send,
                      color: enabled ? Colors.deepPurple : Colors.grey.shade400,
                    ),
                    tooltip: 'Send',
                  ),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.conversationId,
    required this.character,
    required this.awaiting,
    required this.scrollController,
  });

  final String conversationId;
  final AiCharacter? character;
  final bool awaiting;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(chatMessagesProvider(conversationId));

    return messages.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text(
          'This conversation could not be loaded.',
          style: TextStyle(color: Colors.grey.shade600),
        ),
      ),
      data: (items) {
        if (items.isEmpty && !awaiting) {
          return _EmptyState(character: character);
        }

        final showTyping = awaiting;
        final count = items.length + (showTyping ? 1 : 0);

        return ListView.builder(
          controller: scrollController,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          itemCount: count,
          itemBuilder: (context, index) {
            if (showTyping && index == 0) {
              return _TypingBubble(character: character);
            }
            final message = items[showTyping ? index - 1 : index];
            return _Bubble(message: message, character: character);
          },
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.character});

  final CharacterChatMessage message;
  final AiCharacter? character;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final time = message.createdAt == null
        ? ''
        : DateFormat('h:mm a').format(message.createdAt!.toLocal());

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.76,
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: BoxDecoration(
        color: isUser ? Colors.deepPurple.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomLeft: Radius.circular(isUser ? 14 : 4),
          bottomRight: Radius.circular(isUser ? 4 : 14),
        ),
      ),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          SelectableText(
            message.text,
            style: const TextStyle(
              fontSize: 14,
              height: 1.35,
              color: Colors.black87,
            ),
          ),
          if (time.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                time,
                style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500),
              ),
            ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            _Avatar(character: character, size: 26),
            const SizedBox(width: 8),
          ],
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.character});

  final AiCharacter? character;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          _Avatar(character: character, size: 26),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SizedBox(
              height: 10,
              width: 26,
              child: Center(
                child: Text(
                  '•••',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.5,
                    color: Colors.grey.shade500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.character, required this.size});

  final AiCharacter? character;
  final double size;

  @override
  Widget build(BuildContext context) {
    final value = character;
    final fallback = CircleAvatar(
      radius: size / 2,
      backgroundColor: Colors.deepPurple.shade50,
      child: Icon(
        Icons.person_outline,
        size: size * 0.55,
        color: Colors.deepPurple.shade200,
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
  const _EmptyState({required this.character});

  final AiCharacter? character;

  @override
  Widget build(BuildContext context) {
    final name = character?.name ?? 'your character';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Avatar(character: character, size: 72),
            const SizedBox(height: 16),
            Text(
              name,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Say hello. $name will answer in character and remember what '
              'matters as you talk.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }
}
