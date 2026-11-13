import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:yoked_in/ai/screens/meeting_minutes_list_screen.dart';
import 'package:yoked_in/ai/widgets/ai_chat_summary_sheet.dart';
import 'package:yoked_in/chat/chat_title.dart';
import 'package:yoked_in/chat/message_image.dart';
import 'package:yoked_in/chat/message_model.dart';
import 'package:yoked_in/chat/user_model.dart';
import 'package:yoked_in/chat/video_audio_history.dart';
import 'package:yoked_in/helper/date_time_helper.dart';
import 'package:yoked_in/provider/chat_provider.dart';
import 'package:yoked_in/widgets/utilis.dart';
import 'package:yoked_in/widgets/video_audio_call_button.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String chatId;
  final UserModel otherUser;

  const ChatScreen({super.key, required this.chatId, required this.otherUser});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  bool _isUploadingImage = false;

  /// Older messages are appended as the user scrolls up; the live stream only
  /// carries the newest page.
  static const int _pageSize = 30;
  final List<MessageModel> _olderMessages = [];
  List<MessageModel> _latestLiveMessages = const [];
  bool _isLoadingOlder = false;
  bool _hasMoreOlder = true;

  /// Built once. Creating the Firestore stream inside build() re-ran the query
  /// on every rebuild, so typing, sending a photo or any provider update
  /// re-downloaded the page of messages and made the list flicker.
  late final Stream<List<MessageModel>> _messagesStream =
      ref.read(chatServiceProvider).getChatMessages(widget.chatId);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onMessagesScroll);
    // Attach listener to track focus events on text field
    _textFieldFocusNode.addListener(() {
      if (_textFieldFocusNode.hasFocus) {
        _handleTextFieldFocus();
      } else {
        _handleTextFieldUnfocus();
      }
    });
  }

  Timer? _readStatusTimer;
  List<String> unreadMessageIds = [];

  /// MESSAGE READ HANDLER
  Future<void> _markAsRead() async {
    _readStatusTimer?.cancel();
    _readStatusTimer = Timer(const Duration(milliseconds: 500), () async {
      final chatService = ref.read(chatServiceProvider);
      await chatService.markMessagesAsRead(widget.chatId);
      unreadMessageIds.clear();
    });
  }

  Timer? _typingTimer;
  bool _isCurrentlyTyping = false;
  bool _isTextFieldFocused = false;
  Timer? _typingDebounceTimer;

  /// TYPING INDICATOR HANDLER
  void _handleTextChange(String text) {
    // Cancel previous timer
    _typingDebounceTimer?.cancel();

    if (text.trim().isNotEmpty && _isTextFieldFocused) {
      if (!_isCurrentlyTyping) {
        _isCurrentlyTyping = true;
        ref.read(typingProvider(widget.chatId).notifier).setTyping(true);
      }

      // Set timer to stop typing after 2 seconds of no typing
      _typingDebounceTimer = Timer(const Duration(seconds: 2), () {
        _handleTypingStop();
      });
    } else {
      _handleTypingStop();
    }
  }

  void _handleTypingStart() {
    if (!_isCurrentlyTyping) {
      _isCurrentlyTyping = true;
      ref.read(typingProvider(widget.chatId).notifier).setTyping(true);
    }

    // Cancel any existing timer - DON'T set a new one
    _typingTimer?.cancel();
  }

  void _handleTypingStop() {
    if (_isCurrentlyTyping) {
      _isCurrentlyTyping = false;
      ref.read(typingProvider(widget.chatId).notifier).setTyping(false);
    }
    _typingTimer?.cancel();
  }

  void _handleTextFieldFocus() {
    _isTextFieldFocused = true;
    // Start typing indicator if there's already text
    if (_messageController.text.trim().isNotEmpty) {
      _handleTypingStart();
    }
  }

  void _handleTextFieldUnfocus() {
    _isTextFieldFocused = false;
    _handleTypingStop();
  }

  /// The live page followed by every older page that has been loaded.
  List<MessageModel> _mergeMessages(List<MessageModel> live) {
    if (_olderMessages.isEmpty) return live;

    final seen = live.map((message) => message.messageId).toSet();
    return [
      ...live,
      ..._olderMessages.where((message) => !seen.contains(message.messageId)),
    ];
  }

  /// The list is reversed, so the oldest message sits at maxScrollExtent.
  void _onMessagesScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 400) return;
    _loadOlderMessages();
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlder || !_hasMoreOlder) return;

    final loaded = _mergeMessages(_latestLiveMessages);
    if (loaded.isEmpty) return;

    final before = loaded.last.timestamp;
    if (before == null) {
      _hasMoreOlder = false;
      return;
    }

    setState(() => _isLoadingOlder = true);

    try {
      final page = await ref.read(chatServiceProvider).loadOlderMessages(
            widget.chatId,
            before: before,
            limit: _pageSize,
          );
      if (!mounted) return;

      final known = loaded.map((message) => message.messageId).toSet();
      final fresh = page
          .where((message) => !known.contains(message.messageId))
          .toList();

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

  /// SEND TEXT MESSAGE
  Future<void> _sendMessage() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) return;
    _messageController.clear();

    // Stop typing when message is sent
    _handleTypingStop();
    // Reset the flag to allow marking as read for responses
    final chatService = ref.read(chatServiceProvider);
    final result = await chatService.sendMessage(
      chatId: widget.chatId,
      message: message,
    );

    if (result != 'success' && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to send message: $result')),
      );
    }

    // Auto scroll to bottom after sending
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

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.removeListener(_onMessagesScroll);
    _scrollController.dispose();
    _textFieldFocusNode.dispose(); // Add this
    _typingTimer?.cancel();
    _readStatusTimer?.cancel(); // Add this
    // Stop typing when leaving chat
    if (_isCurrentlyTyping) {
      ref.read(typingProvider(widget.chatId).notifier).setTyping(false);
    }
    super.dispose();
  }

  final FocusNode _textFieldFocusNode = FocusNode();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        forceMaterialTransparency: true,
        backgroundColor: Colors.white,
        title: TitleOfChatScreen(widget: widget),
        // In your AppBar actions:
        actions: [
          actionButton(
            context,
            false,
            widget.otherUser.uid,
            widget.otherUser.name,
            widget.chatId,
            ref,
          ),
          // Video call button
          actionButton(
            context,
            true,
            widget.otherUser.uid,
            widget.otherUser.name,
            widget.chatId,
            ref,
          ),
          // Popup menu -> Minutes, AI Summary & End Connection
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'minutes') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MeetingMinutesListScreen(
                      conversationId: widget.chatId,
                      conversationTitle: widget.otherUser.name,
                      conversationType: 'private',
                      otherUserId: widget.otherUser.uid,
                    ),
                  ),
                );
              } else if (value == 'summarize') {
                showChatSummaryBottomSheet(
                  context: context,
                  ref: ref,
                  conversationId: widget.chatId,
                  conversationTitle: widget.otherUser.name,
                  isGroup: false,
                  otherUserId: widget.otherUser.uid,
                );
              } else if (value == 'unfriend') {
                final result = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Disconnect'),
                    content: Text(
                      'Are you sure you want to Disconnect ${widget.otherUser.name}?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ),
                );
                // if confirmed -> unfriend
                if (result == true) {
                  final unfriendResult = await ref
                      .read(chatServiceProvider)
                      .unfriendUser(widget.chatId, widget.otherUser.uid);

                  if (unfriendResult == 'success' && context.mounted) {
                    Navigator.pop(context);
                    showAppSnackbar(
                      context: context,
                      type: SnackbarType.success,
                      description: "You Have Been Disconnected",
                    );
                  }
                }
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'minutes',
                child: Text('Minutes'),
              ),
              const PopupMenuItem(
                value: 'summarize',
                child: Text('Summarize Chat (AI)'),
              ),
              const PopupMenuItem(
                value: 'unfriend',
                child: Text('End Connection'),
              ),
            ],
          ),
        ],
      ),

      /// CHAT BODY
      body: Column(
        children: [
          // Messages section
          Expanded(
            child: StreamBuilder<List<MessageModel>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                // Loading
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                // Error
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }

                _latestLiveMessages = snapshot.data ?? const [];
                final messages = _mergeMessages(_latestLiveMessages);
                if (snapshot.hasData && messages.isNotEmpty) {
                  final currentUserId = FirebaseAuth.instance.currentUser!.uid;
                  final hasUnreadMessages = messages.any(
                    (msg) =>
                        msg.senderId != currentUserId &&
                        !(msg.readBy?.containsKey(currentUserId) ?? false),
                  );

                  if (hasUnreadMessages) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _markAsRead();
                    });
                  }
                }
                // Empty chat UI
                if (messages.isEmpty) {
                  return const Center(
                    child: Text(
                      'No messages yet. Start the conversation!',
                      style: TextStyle(color: Colors.grey),
                    ),
                  );
                }
                // Build message list
                return ListView.builder(
                  controller: _scrollController,
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
                    final isMe = message.senderId ==
                        FirebaseAuth.instance.currentUser!.uid;
                    final isSystem = message.type == 'system';
                    final showDateSeparator = shouldShowDateHeader(
                      messages,
                      index,
                    );
                    final isVideo = message.callType == 'video';
                    final isMissed = message.callStatus == 'missed';

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
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[200],
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    formatDateHeader(message.timestamp),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey[600],
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                const Expanded(child: Divider()),
                              ],
                            ),
                          ),
                        if (isSystem)
                          Container(
                            margin: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 16,
                            ),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              message.message,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontStyle: FontStyle.italic,
                                color: Colors.grey,
                              ),
                            ),
                          )
                        else if (message.type == 'call')
                          VideoAndAudioCallHistory(
                            isMe: isMe,
                            widget: widget,
                            isMissed: isMissed,
                            isVideo: isVideo,
                            message: message,
                          )
                        // In your itemBuilder, add this condition for call messages:
                        // Normal chat message
                        else
                          MessageAndImageDisplay(
                            isMe: isMe,
                            widget: widget,
                            message: message,
                          ),

                        // ADD THIS AT THE END (this is the date header):
                      ],
                    );
                  },
                );
              },
            ),
          ),

          /// MESSAGE INPUT BAR
          Container(
            padding: const EdgeInsets.only(
              top: 5,
              right: 10,
              left: 10,
              bottom: 15,
            ),
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
                // Image picker button
                IconButton(
                  onPressed: _isUploadingImage ? null : _showMediaOptions,
                  tooltip: 'Attach media',
                  icon: Icon(
                    Icons.attach_file,
                    size: 28,
                    color: _isUploadingImage ? Colors.grey : Colors.blue,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    focusNode: _textFieldFocusNode,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(25),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: Colors.grey[100],
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    maxLines: null,
                    onSubmitted: (value) => _sendMessage(),
                    onChanged: _handleTextChange,
                    onTap: _handleTextFieldFocus,
                  ),
                ),

                const SizedBox(width: 4),

// Send button.
                FloatingActionButton(
                  onPressed: _isUploadingImage ? null : _sendMessage,
                  mini: true,
                  elevation: 0,
                  backgroundColor: Colors.transparent,
                  child: _isUploadingImage
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.send,
                          color: Colors.blueAccent,
                          size: 30,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// IMAGE HANDLING METHODS
  // these methods is for image picker :

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        await _showImagePreview(pickedFile);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackbar(
          context: context,
          type: SnackbarType.error,
          description: 'Error picking image: $e',
        );
      }
    }
  }

  // Preview image before sending
  Future<void> _showImagePreview(XFile imageFile) async {
    final captionController = TextEditingController();

    try {
      final imageBytes = await imageFile.readAsBytes();

      if (!mounted) return;

      final result = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          contentPadding: const EdgeInsets.all(16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                constraints: const BoxConstraints(maxHeight: 300),
                child: Image.memory(
                  imageBytes,
                  fit: BoxFit.contain,
                  cacheWidth: (MediaQuery.sizeOf(context).width *
                          MediaQuery.devicePixelRatioOf(context))
                      .round()
                      .clamp(320, 1600),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: captionController,
                decoration: const InputDecoration(
                  hintText: 'Add a caption (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Send'),
            ),
          ],
        ),
      );

      if (result == true && mounted) {
        await _sendImageMessage(
          imageFile,
          captionController.text.trim(),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackbar(
          context: context,
          type: SnackbarType.error,
          description: 'Unable to preview image: $e',
        );
      }
    } finally {
      captionController.dispose();
    }
  }

  // Send image to Firestore/Storage
  Future<void> _sendImageMessage(XFile imageFile, String caption) async {
    setState(() {
      _isUploadingImage = true;
    });

    try {
      final chatService = ref.read(chatServiceProvider);
      final result = await chatService.sendImageWithUpload(
        chatId: widget.chatId,
        imageFile: imageFile,
        caption: caption.isEmpty ? null : caption,
      );

      if (result == 'success') {
        // Auto scroll to bottom after sending
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0.0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      } else {
        if (mounted) {
          showAppSnackbar(
            context: context,
            type: SnackbarType.error,
            description: 'Failed to send image: $result',
          );
        }
      }
    } catch (e) {
      if (mounted) {
        showAppSnackbar(
          context: context,
          type: SnackbarType.error,
          description: 'Error sending image: $e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploadingImage = false;
        });
      }
    }
  }

  // Only picture attachments are supported in private chats.
  void _showMediaOptions() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose image'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickImage(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }
}
