import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/chat/chat_screen.dart';
import 'package:yoked_in/provider/chat_provider.dart';
import 'package:yoked_in/provider/user_status_provider.dart';
import 'package:yoked_in/widgets/dot_indicator.dart';
import 'package:yoked_in/widgets/user_avatar.dart';
import 'package:yoked_in/other_screens/view_user_profile_screen.dart';

class TitleOfChatScreen extends StatelessWidget {
  const TitleOfChatScreen({super.key, required this.widget});

  final ChatScreen widget;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final statusAsync = ref.watch(userStatusProvider(widget.otherUser.uid));
        final typingStatus = ref.watch(typingProvider(widget.chatId));
        final isOtherUserTyping = typingStatus[widget.otherUser.uid] ?? false;

        return statusAsync.when(
          data: (isOnline) => Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => ViewUserProfileScreen(userId: widget.otherUser.uid))),
                child: UserAvatar(
                  photoUrl: widget.otherUser.photoURL,
                  radius: 18,
                  fallbackIcon: Icons.person,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(
                        builder: (_) => ViewUserProfileScreen(userId: widget.otherUser.uid))),
                      child: Text(widget.otherUser.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    // TYPING INDICATOR LOGIC
                    if (isOtherUserTyping)
                      Row(
                        children: [
                          Text(
                            'typing',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue[600],
                            ),
                          ),
                          SizedBox(width: 4),
                          ThreeDots(),
                        ],
                      )
                    else if (isOnline)
                      const Text(
                        'Online',
                        style: TextStyle(fontSize: 12, color: Colors.green),
                      ),
                  ],
                ),
              ),
            ],
          ),
          loading: () => Text(widget.otherUser.name),
          error: (_, __) => Text(widget.otherUser.name),
        );
      },
    );
  }
}
