import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/calls/call_recording_models.dart';
import 'package:yoked_in/provider/chat_provider.dart';
import 'package:zego_uikit/zego_uikit.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';

ZegoSendCallInvitationButton actionButton(
  BuildContext context,
  bool isVideo,
  String receiverId,
  String receiverName,
  String chatId,
  WidgetRef ref, // Add ref parameter
) =>
    ZegoSendCallInvitationButton(
      iconSize: Size(30, 30),
      buttonSize: Size(40, 40),
      isVideoCall: isVideo,
      resourceID: "zego_call",
      // Carries the chat id to both devices so a recording made during the
      // call can be linked to this conversation's minutes.
      customData: CallConversationInfo(
        conversationId: chatId,
        conversationType: 'private',
        title: receiverName,
      ).toCustomData(),
      invitees: [ZegoUIKitUser(id: receiverId, name: receiverName)],
      onPressed: (code, message, errorInvitees) {
        if (code.isEmpty) {
          ref.read(chatServiceProvider).addCallHistory(
                chatId: chatId,
                isVideoCall: isVideo,
                callStatus: '_',
              );
          return;
        }

        final failedInvitees = errorInvitees.join(', ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failedInvitees.isEmpty
                  ? 'Call invitation failed: $message'
                  : 'Call invitation failed for $failedInvitees: $message',
            ),
            backgroundColor: Colors.red,
          ),
        );
      },
    );
