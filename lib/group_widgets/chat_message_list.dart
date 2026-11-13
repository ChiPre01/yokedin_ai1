import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/group_chat/group_chat_model.dart';
import 'package:yoked_in/group_widgets/chat_message.dart';
import 'package:yoked_in/helper/group_chat_date_time_manager.dart';
import 'package:yoked_in/provider/group_chat_provider.dart';

class ChatMessagesList extends ConsumerStatefulWidget {
  final String groupId;
  final ScrollController scrollController;

  const ChatMessagesList({
    super.key,
    required this.groupId,
    required this.scrollController,
  });

  @override
  ConsumerState<ChatMessagesList> createState() => _ChatMessagesListState();
}

class _ChatMessagesListState extends ConsumerState<ChatMessagesList> {
  /// Created once. Building the Firestore stream inside build() re-subscribed
  /// on every rebuild, so each keystroke or provider update re-ran the query
  /// and re-downloaded the whole page of group messages.
  static const int _pageSize = 30;
  final List<GroupMessageModel> _olderMessages = [];
  List<GroupMessageModel> _latestLiveMessages = const [];
  bool _isLoadingOlder = false;
  bool _hasMoreOlder = true;

  late Stream<List<GroupMessageModel>> _messagesStream =
      ref.read(groupChatServiceProvider).getGroupMessages(widget.groupId);

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatMessagesList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groupId != widget.groupId) {
      _messagesStream =
          ref.read(groupChatServiceProvider).getGroupMessages(widget.groupId);
      _olderMessages.clear();
      _hasMoreOlder = true;
    }
  }

  /// The live page followed by every older page loaded so far.
  List<GroupMessageModel> _merge(List<GroupMessageModel> live) {
    if (_olderMessages.isEmpty) return live;

    final seen = live.map((message) => message.messageId).toSet();
    return [
      ...live,
      ..._olderMessages.where((message) => !seen.contains(message.messageId)),
    ];
  }

  /// The list is reversed, so older messages live near maxScrollExtent.
  void _onScroll() {
    if (!widget.scrollController.hasClients) return;
    final position = widget.scrollController.position;
    if (position.pixels < position.maxScrollExtent - 400) return;
    _loadOlder();
  }

  Future<void> _loadOlder() async {
    if (_isLoadingOlder || !_hasMoreOlder) return;

    final loaded = _merge(_latestLiveMessages);
    if (loaded.isEmpty) return;

    final before = loaded.last.timestamp;
    if (before == null) {
      _hasMoreOlder = false;
      return;
    }

    setState(() => _isLoadingOlder = true);

    try {
      final page = await ref
          .read(groupChatServiceProvider)
          .loadOlderGroupMessages(
            widget.groupId,
            before: before,
            limit: _pageSize,
          );
      if (!mounted) return;

      final known = loaded.map((message) => message.messageId).toSet();
      final fresh =
          page.where((message) => !known.contains(message.messageId)).toList();

      setState(() {
        _olderMessages.addAll(fresh);
        _hasMoreOlder = page.length >= _pageSize;
        _isLoadingOlder = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingOlder = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = FirebaseAuth.instance.currentUser?.uid ?? '';

    return StreamBuilder<List<GroupMessageModel>>(
      stream: _messagesStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: ${snapshot.error}'),
              ],
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        _latestLiveMessages = snapshot.data ?? const [];
        final messages = _merge(_latestLiveMessages);
        if (messages.isEmpty) {
          return const Center(
            child: Text('No messages yet. Start the conversation!'),
          );
        }

        return ListView.builder(
          controller: widget.scrollController,
          reverse: true,
          itemCount: messages.length + (_isLoadingOlder ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= messages.length) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final message = messages[index];
            final showDateSeparator = shouldShowDateSeparator(index, messages);

            return Column(
              children: [
                if (showDateSeparator)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        const Expanded(child: Divider()),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            getDateLabel(message.timestamp ?? DateTime.now()),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                  ),
                if (message.type == 'system')
                  Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        message.message,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  )
                else
                  ChatMessage(
                    message: message,
                    isMe: message.senderId == currentUserId,
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
