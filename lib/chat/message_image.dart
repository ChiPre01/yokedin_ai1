import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:yoked_in/chat/chat_screen.dart';
import 'package:yoked_in/chat/message_model.dart';
import 'package:yoked_in/helper/current_time.dart';
import 'package:yoked_in/helper/time_format.dart';
import 'package:yoked_in/provider/user_status_provider.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';
import 'package:yoked_in/widgets/full_screen_image.dart';
import 'package:yoked_in/widgets/message_status_icon.dart';
import 'package:yoked_in/widgets/user_avatar.dart';

/// Displays ordinary text and picture messages in a private chat.
/// Video, audio, voice-note, and document attachments are intentionally not
/// rendered; private-chat media is limited to pictures.
class MessageAndImageDisplay extends ConsumerWidget {
  const MessageAndImageDisplay({
    super.key,
    required this.isMe,
    required this.widget,
    required this.message,
  });

  final bool isMe;
  final ChatScreen widget;
  final MessageModel message;

  String? get _imageUrl {
    try {
      final dynamic mediaCategory = (message as dynamic).mediaCategory;
      if (mediaCategory is String && mediaCategory.toLowerCase() != 'image') {
        return null;
      }
    } catch (_) {
      // Older message models may not have mediaCategory.
    }

    try {
      final dynamic mediaUrl = (message as dynamic).mediaUrl;
      if (mediaUrl is String && mediaUrl.trim().isNotEmpty) {
        return mediaUrl.trim();
      }
    } catch (_) {
      // Older picture messages use imageUrl.
    }

    final url = message.imageUrl;
    if (url != null && url.trim().isNotEmpty) return url.trim();
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One shared listener per user, reused by every bubble in the list.
    final isReceiverOnline =
        ref.watch(userStatusProvider(widget.otherUser.uid)).asData?.value ??
            false;

    final category = message.type.toLowerCase();
    const unsupportedMediaTypes = {
      'video',
      'voice',
      'voice_note',
      'voicenote',
      'audio',
      'document',
      'file',
    };
    if (unsupportedMediaTypes.contains(category)) {
      return const SizedBox.shrink();
    }

    final imageUrl = _imageUrl;
    final hasImage = imageUrl != null;
    final text = message.message;
    final hasText = text.trim().isNotEmpty;
    final hasBoth = hasImage && hasText;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            UserAvatar(
              photoUrl: widget.otherUser.photoURL,
              radius: 16,
              fallbackIcon: Icons.person,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.7,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: hasImage ? 8 : 10,
                vertical: hasImage ? 4 : 10,
              ),
              decoration: BoxDecoration(
                color: hasImage
                    ? Colors.white
                    : isMe
                        ? Colors.blue
                        : Colors.grey[300],
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasImage)
                    GestureDetector(
                      onTap: () => showFullScreenImage(imageUrl, context),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CloudflareMediaImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          width: 250,
                          loading: const SizedBox(
                            width: 250,
                            height: 200,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                          error: Container(
                            width: 250,
                            height: 200,
                            color: Colors.grey.shade300,
                            alignment: Alignment.center,
                            child: const Icon(Icons.broken_image, size: 48),
                          ),
                        ),
                      ),
                    ),
                  if (hasImage && hasText) const SizedBox(height: 8),
                  if (hasText)
                    Text(
                      text,
                      style: TextStyle(
                        color: hasBoth
                            ? Colors.black
                            : isMe
                                ? Colors.white
                                : Colors.black87,
                      ),
                    ),
                  const SizedBox(height: 4),
                  if (hasImage)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          currentTime(message.timestamp),
                          if (isMe) ...[
                            const SizedBox(width: 4),
                            buildMessageStatusIcon(
                              message,
                              receiverUid: widget.otherUser.uid,
                              isReceiverOnline: isReceiverOnline,
                            ),
                          ],
                        ],
                      ),
                    )
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (isMe)
                          Text(
                            formatMessageTime(message.timestamp),
                            style: TextStyle(
                              fontSize: 10,
                              color: isMe ? Colors.white : Colors.black54,
                            ),
                          )
                        else
                          Text(
                            formatMessageTime(message.timestamp),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.black54,
                            ),
                          ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          buildMessageStatusIcon(
                            message,
                            receiverUid: widget.otherUser.uid,
                            isReceiverOnline: isReceiverOnline,
                          ),
                        ],
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
