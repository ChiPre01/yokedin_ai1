import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:yoked_in/ai/screens/meeting_minutes_list_screen.dart';
import 'package:yoked_in/group_chat/group_chat_model.dart';
import 'package:yoked_in/group_chat/group_chat_services.dart';
import 'package:yoked_in/group_chat/group_info_screen.dart';
import 'package:yoked_in/group_widgets/chat_input_bar.dart';
import 'package:yoked_in/group_widgets/chat_message_list.dart';
import 'package:yoked_in/group_widgets/group_call_button.dart';
import 'package:yoked_in/group_widgets/group_member_count.dart';
import 'package:yoked_in/group_widgets/image_preview.dart';
import 'package:yoked_in/provider/group_chat_provider.dart';
import 'package:yoked_in/widgets/dot_indicator.dart';
import 'package:yoked_in/widgets/user_avatar.dart';
import 'package:yoked_in/widgets/utilis.dart';

class GroupChatScreen extends ConsumerStatefulWidget {
  final GroupModel group;

  const GroupChatScreen({super.key, required this.group});

  @override
  ConsumerState<GroupChatScreen> createState() => _GroupChatScreen();
}

class _GroupChatScreen extends ConsumerState<GroupChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  Timer? _typingTimer;
  bool _isTyping = false;

  @override
  void initState() {
    super.initState();
    _checkMembership();
    _markMessagesAsRead();
  }

  void _checkMembership() {
    final currentUserId = FirebaseAuth.instance.currentUser!.uid;
    if (!widget.group.members.contains(currentUserId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pop(context);
        showAppSnackbar(
          context: context,
          type: SnackbarType.success,
          description: 'You are no longer a member of this group',
        );
      });
    }
  }

  Future<void> _markMessagesAsRead() async {
    await ref
        .read(groupChatServiceProvider)
        .markGroupMessagesAsRead(widget.group.groupId);
  }

  void _onTextChanged(String text) {
    if (!mounted) return;
    if (text.isNotEmpty && !_isTyping) {
      _isTyping = true;
      ref
          .read(groupTypingProvider(widget.group.groupId).notifier)
          .setTyping(true);
    }

    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (_isTyping) {
        _isTyping = false;
        ref
            .read(groupTypingProvider(widget.group.groupId).notifier)
            .setTyping(false);
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    _isTyping = false;
    ref
        .read(groupTypingProvider(widget.group.groupId).notifier)
        .setTyping(false);

    final result = await ref
        .read(groupChatServiceProvider)
        .sendGroupMessage(groupId: widget.group.groupId, message: text);

    if (result != 'success' && mounted) {
      showAppSnackbar(
        context: context,
        type: SnackbarType.error,
        description: "Unable to complete a process",
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendImage() async {
    try {
      final picker = ImagePicker();

      final XFile? pickedFile = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (pickedFile != null && mounted) {
        _showImagePreviewDialog(pickedFile);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackbar(
          context: context,
          type: SnackbarType.error,
          description: 'Unable to select image: $e',
        );
      }
    }
  }

  Future<void> _showImagePreviewDialog(XFile imageFile) async {
    final caption = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => ImagePreviewDialog(
        imageFile: imageFile,
      ),
    );

    if (caption != null && mounted) {
      await _uploadAndSendImage(imageFile, caption);
    }
  }

  Future<void> _uploadAndSendImage(
    XFile imageFile,
    String caption,
  ) async {
    if (!mounted) return;

    ref.read(isUploadingProvider(widget.group.groupId).notifier).state = true;

    try {
      final imageUrl = await ref
          .read(groupChatServiceProvider)
          .uploadImage(imageFile, widget.group.groupId);

      if (!mounted) return;

      if (imageUrl.isNotEmpty) {
        await ref.read(groupChatServiceProvider).sendGroupImageMessage(
              groupId: widget.group.groupId,
              imageUrl: imageUrl,
              caption: caption.trim().isEmpty ? null : caption.trim(),
            );
        if (!mounted) return;

        showAppSnackbar(
          context: context,
          type: SnackbarType.success,
          description: 'Image sent successfully',
        );
      } else {
        showAppSnackbar(
          context: context,
          type: SnackbarType.error,
          description: 'Failed to upload image. Please try again.',
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackbar(
          context: context,
          type: SnackbarType.error,
          description: 'Unable to send image: $e',
        );
      }
    } finally {
      if (mounted) {
        ref.read(isUploadingProvider(widget.group.groupId).notifier).state =
            false;
      }
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _typingTimer?.cancel();

    try {
      GroupChatService().markGroupMessagesAsRead(widget.group.groupId);
      GroupChatService().setGroupTypingStatus(widget.group.groupId, false);
    } catch (e) {
      // Ignore errors during disposal
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typingUsers = ref.watch(
      groupTypingUsersProvider(widget.group.groupId),
    );
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        actions: [
          GroupCallButton(group: widget.group, isVideoCall: false),
          GroupCallButton(group: widget.group, isVideoCall: true),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'minutes') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MeetingMinutesListScreen(
                      conversationId: widget.group.groupId,
                      conversationTitle: widget.group.groupName,
                      conversationType: 'group',
                    ),
                  ),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'minutes',
                child: Text('Minutes'),
              ),
            ],
          ),
          const SizedBox(width: 8),
        ],
        title: GestureDetector(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  GroupInfoScreen(groupId: widget.group.groupId),
            ),
          ),
          child: Row(
            children: [
              UserAvatar(
                photoUrl: widget.group.groupPhotoURL,
                radius: 20,
                fallbackIcon: Icons.group,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.group.groupName,
                      style: const TextStyle(fontSize: 16),
                    ),
                    typingUsers.isNotEmpty
                        ? Row(
                            children: [
                              Text(
                                "Typing",
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.green,
                                ),
                              ),
                              ThreeDots(),
                            ],
                          )
                        : GroupMemberCount(
                            groupId: widget.group.groupId,
                            style: TextStyle(fontSize: 13, color: Colors.grey),
                            suffix: ' members',
                          ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ChatMessagesList(
              groupId: widget.group.groupId,
              scrollController: _scrollController,
            ),
          ),
          ChatInputBar(
            groupId: widget.group.groupId,
            messageController: _messageController,
            onTextChanged: _onTextChanged,
            onSendMessage: _sendMessage,
            onSendImage: _sendImage,
          ),
        ],
      ),
    );
  }
}
