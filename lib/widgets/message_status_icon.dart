import 'package:flutter/material.dart';
import 'package:yoked_in/chat/message_model.dart';

/// Builds the "message status" icon (✓, ✓✓, read check).
///
/// The receiver's online state is passed in instead of being read here: this
/// widget is built once per message, and opening its own Firestore listener for
/// every bubble meant a chat screen could hold dozens of duplicate listeners on
/// the same user document.
Widget buildMessageStatusIcon(
  MessageModel message, {
  required String receiverUid,
  required bool isReceiverOnline,
}) {
  final isMessageRead = message.readBy?.containsKey(receiverUid) ?? false;

  if (isMessageRead) {
    // Message was read by the receiver → ✓✓
    return const Icon(Icons.done_all, size: 16, color: Colors.white);
  }

  if (isReceiverOnline) {
    // Receiver is online but has not read it → grey ✓✓
    return const Icon(Icons.done_all, size: 16, color: Colors.black54);
  }

  // Delivered while the receiver is offline → single ✓
  return const Icon(Icons.check, size: 16, color: Colors.black54);
}
