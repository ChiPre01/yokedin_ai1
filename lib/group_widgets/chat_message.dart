import 'package:flutter/material.dart';
import 'package:yoked_in/group_chat/group_chat_model.dart';
import 'package:yoked_in/helper/current_time.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';
import 'package:yoked_in/widgets/full_screen_image.dart';
import 'package:yoked_in/widgets/user_avatar.dart';

class ChatMessage extends StatelessWidget {
  final GroupMessageModel message;
  final bool isMe;

  const ChatMessage({super.key, required this.message, required this.isMe});

  @override
  Widget build(BuildContext context) {
    const unsupportedMediaTypes = {
      'video',
      'voice',
      'voice_note',
      'voicenote',
      'audio',
      'document',
      'file',
    };
    if (unsupportedMediaTypes.contains(message.type.toLowerCase())) {
      return const SizedBox.shrink();
    }

    final hasImage = message.imageUrl != null;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              UserAvatar(
                photoUrl: message.senderPhotoURL,
                radius: 16,
                fallbackIcon: Icons.person,
              ),
            if (!isMe) const SizedBox(width: 8),
            Flexible(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                padding: EdgeInsets.all(hasImage ? 4 : 12),
                decoration: BoxDecoration(
                  color: isMe ? Colors.green[50] : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.imageUrl != null)
                      Stack(
                        children: [
                          GestureDetector(
                            onTap: () {
                              if (message.imageUrl != null &&
                                  message.imageUrl!.isNotEmpty) {
                                showFullScreenImage(message.imageUrl!, context);
                              }
                            },
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(5),
                              child: CloudflareMediaImage(
                                imageUrl: message.imageUrl!,
                                fit: BoxFit.cover,
                                loading: const SizedBox(
                                  height: 200,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                                error: Container(
                                  height: 200,
                                  color: Colors.grey,
                                  child: const Icon(
                                    Icons.broken_image,
                                    size: 50,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            bottom: 2,
                            right: 5,
                            child: Container(
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.white,
                                    spreadRadius: 5,
                                    blurRadius: 15,
                                  ),
                                ],
                              ),
                              child: currentTime(message.timestamp),
                            ),
                          ),
                        ],
                      ),
                    // Display ordinary text messages received from other group members.
                    if (!isMe && !hasImage && message.message.trim().isNotEmpty)
                      Text(
                        message.message,
                        style: const TextStyle(
                          color: Colors.black,
                        ),
                      ),

// Display image captions for both the sender and other group members.
                    if (hasImage && message.message.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
                        child: Text(
                          message.message,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    if (isMe && !hasImage)
                      Wrap(
                        children: [
                          Text(
                            message.message,
                            style: const TextStyle(color: Colors.black),
                          ),
                          const SizedBox(width: 10),
                          currentTime(message.timestamp),
                        ],
                      ),
                    if (!hasImage)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!isMe)
                            Flexible(
                              child: Text(
                                message.senderName,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: const TextStyle(
                                  color: Colors.orange,
                                  fontWeight: FontWeight.w400,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          if (!isMe) const SizedBox(width: 5),
                          if (!isMe) currentTime(message.timestamp),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
