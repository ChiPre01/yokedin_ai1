import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:yoked_in/group_chat/group_chat_model.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';

class GroupChatService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String get currentUserId => _auth.currentUser?.uid ?? '';

  // Check if users are friends
  Future<bool> areUsersFriends(String userId1, String userId2) async {
    final chatId = _generateChatId(userId1, userId2);
    // Only read from Firestore if not cached
    final friendship =
        await _firestore.collection('friendships').doc(chatId).get();

    final exists = friendship.exists;
    return exists;
  }

  // -------------------- UTILS --------------------
  String _generateChatId(String userId1, String userId2) {
    final ids = [userId1, userId2]..sort();
    return '${ids[0]}_${ids[1]}';
  }

  // -------------------- Create a new group --------------------

  // Create a new group
  Future<String> createGroup({
    required String groupName,
    required List<String> memberIds, // Must be friends
    String? groupPhotoURL,
  }) async {
    try {
      final currentUser = _auth.currentUser!;

      // Verify all members are friends
      for (String memberId in memberIds) {
        if (memberId != currentUserId) {
          bool areFriends = await areUsersFriends(currentUserId, memberId);
          if (!areFriends) {
            return 'Can only add friends to group';
          }
        }
      }

      final groupId = _firestore.collection('groups').doc().id;
      final allMembers = {...memberIds, currentUserId}.toList();

      // ✅ Initialize unread count for all members
      final unreadCount = <String, int>{};
      for (String memberId in allMembers) {
        unreadCount[memberId] = 0;
      }

      final group = GroupModel(
        groupId: groupId,
        groupName: groupName,
        groupPhotoURL: groupPhotoURL,
        members: allMembers,
        admins: [currentUserId], // Creator is admin
        createdBy: currentUserId,
        createdAt: DateTime.now(),
        unreadCount: unreadCount,
      );

      await _firestore.collection('groups').doc(groupId).set(group.toMap());

      // Add system message
      final messageId = _firestore.collection('groupMessages').doc().id;
      await _firestore.collection('groupMessages').doc(messageId).set({
        'messageId': messageId,
        'groupId': groupId,
        'senderId': 'system',
        'senderName': 'System',
        'message': '${currentUser.displayName ?? "Someone"} created the group',
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'system',
      });

      return 'success';
    } catch (e) {
      print('Error creating group: $e');
      return e.toString();
    }
  }

  // -------------------- IMAGE MESSAGES IN GROUP --------------------

  Future<String> uploadImage(XFile imageFile, String groupId) async {
    try {
      final result = await CloudflareMediaService.instance.uploadFile(
        imageFile,
        purpose: 'group',
        groupId: groupId,
        category: 'image',
      );

      final imageUrl = result['url'];

      if (imageUrl is! String || imageUrl.isEmpty) {
        throw Exception('Cloudflare did not return an image URL.');
      }

      return imageUrl;
    } catch (e) {
      print('Error uploading group image to Cloudflare R2: $e');
      return '';
    }
  }

  //  Get user's groups
  Stream<List<GroupModel>> getUserGroups() {
    if (currentUserId.isEmpty) return Stream.value([]);

    return _firestore
        .collection('groups')
        .where('members', arrayContains: currentUserId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map((doc) => GroupModel.fromMap(doc.data()))
              .toList(),
        );
  }

  // Send group message
  Future<String> sendGroupMessage({
    required String groupId,
    required String message,
  }) async {
    try {
      final currentUser = _auth.currentUser!;
      final messageId = _firestore.collection('groupMessages').doc().id;

      // Get sender photo
      final userDoc =
          await _firestore.collection('users').doc(currentUserId).get();
      String? photoURL;
      if (userDoc.exists) {
        photoURL = userDoc.data()?['photoURL'];
      }
      // ✅ Get group data to update unread counts
      final groupDoc = await _firestore.collection('groups').doc(groupId).get();
      if (!groupDoc.exists) {
        return 'Group not found';
      }

      final groupData = groupDoc.data()!;
      final members = List<String>.from(groupData['members'] ?? []);

      final batch = _firestore.batch();

      batch.set(_firestore.collection('groupMessages').doc(messageId), {
        'messageId': messageId,
        'groupId': groupId,
        'senderId': currentUserId,
        'senderName': currentUser.displayName ?? 'User',
        'senderPhotoURL': photoURL,
        'message': message,
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'text',
      });
      // ✅ Update unread count for all members except sender
      final unreadUpdates = <String, dynamic>{
        'lastMessage': message,
        'lastMessageTime': FieldValue.serverTimestamp(),
      };

      for (String memberId in members) {
        if (memberId != currentUserId) {
          unreadUpdates['unreadCount.$memberId'] = FieldValue.increment(1);
        } else {
          unreadUpdates['unreadCount.$memberId'] = 0;
        }
      }

      batch.update(_firestore.collection('groups').doc(groupId), unreadUpdates);

      await batch.commit();
      // ✅ Send notification to group members
      await sendGroupMessageNotification(
        groupId: groupId,
        message: message,
        senderName: currentUser.displayName ?? 'User',
        members: members,
        groupName: groupData['groupName'] ?? 'Group',
      );

      return 'success';
    } catch (e) {
      print('Error sending group message: $e');
      return e.toString();
    }
  }

  // -------------------- Notification --------------------
  Future<void> sendGroupMessageNotification({
    required String groupId,
    required String message,
    required String senderName,
    required List<String> members,
    required String groupName,
  }) async {
    try {
      // Send notification to all group members except sender
      for (String memberId in members) {
        if (memberId != currentUserId) {
          final notificationId = _firestore.collection('users').doc().id;

          await _firestore
              .collection('users')
              .doc(memberId)
              .collection('notifications')
              .doc(notificationId)
              .set({
            'uid': currentUserId,
            'username': senderName,
            'description': message,
            'timestamp': FieldValue.serverTimestamp(),
            'type': 'group_message',
            'groupId': groupId,
            'groupName': groupName,
          });
        }
      }
    } catch (e) {
      print('Error sending group notification: $e');
    }
  }

  Stream<List<GroupMessageModel>> getGroupMessages(
    String groupId, {
    int limit = 50,
  }) {
    return _firestore
        .collection('groupMessages')
        .where('groupId', isEqualTo: groupId)
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
      // Filter out messages with null data and map them
      final messages = <GroupMessageModel>[];
      for (var doc in snapshot.docs) {
        try {
          final message = GroupMessageModel.fromMap(doc.data());
          messages.add(message);
        } catch (e) {
          print('Error parsing message ${doc.id}: $e');
          // Skip malformed messages
        }
      }
      return messages;
    });
  }

  // Add member to group (must be friend)
  Future<String> addGroupMember({
    required String groupId,
    required String userId,
    required String userName,
  }) async {
    try {
      // Check if they are friends
      bool areFriends = await areUsersFriends(currentUserId, userId);
      if (!areFriends) {
        return 'Can only add friends to group';
      }

      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups').doc(groupId);

      batch.update(groupRef, {
        'members': FieldValue.arrayUnion([userId]),
        'unreadCount.$userId': 0, // ✅ Initialize unread count for new member
      });

      // System message
      final messageId = _firestore.collection('groupMessages').doc().id;
      final currentUser = _auth.currentUser!;

      batch.set(_firestore.collection('groupMessages').doc(messageId), {
        'messageId': messageId,
        'groupId': groupId,
        'senderId': 'system',
        'senderName': 'System',
        'message': '${currentUser.displayName ?? "Someone"} added $userName',
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'system',
      });

      await batch.commit();
      return 'success';
    } catch (e) {
      return e.toString();
    }
  }

  // Remove member from group (admin only OR need permission from the admin)
  Future<String> removeGroupMember({
    required String groupId,
    required String userId,
    required String userName,
  }) async {
    try {
      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups').doc(groupId);

      batch.update(groupRef, {
        'members': FieldValue.arrayRemove([userId]),
        'admins': FieldValue.arrayRemove([userId]), // Remove from admins too
      });

      // System message
      final messageId = _firestore.collection('groupMessages').doc().id;
      final currentUser = _auth.currentUser!;

      batch.set(_firestore.collection('groupMessages').doc(messageId), {
        'messageId': messageId,
        'groupId': groupId,
        'senderId': 'system',
        'senderName': 'System',
        'message': '${currentUser.displayName ?? "Someone"} removed $userName',
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'system',
      });

      await batch.commit();
      return 'success';
    } catch (e) {
      return e.toString();
    }
  }

  // Leave group
  Future<String> leaveGroup(String groupId) async {
    try {
      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups').doc(groupId);
      final currentUser = _auth.currentUser!;

      batch.update(groupRef, {
        'members': FieldValue.arrayRemove([currentUserId]),
        'admins': FieldValue.arrayRemove([currentUserId]),
      });

      // System message
      final messageId = _firestore.collection('groupMessages').doc().id;
      batch.set(_firestore.collection('groupMessages').doc(messageId), {
        'messageId': messageId,
        'groupId': groupId,
        'senderId': 'system',
        'senderName': 'System',
        'message': '${currentUser.displayName ?? "Someone"} left the group',
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'system',
      });

      await batch.commit();
      return 'success';
    } catch (e) {
      return e.toString();
    }
  }

  // Update group info (name/photo)
  Future<String> updateGroupInfo({
    required String groupId,
    String? newName,
    String? newPhotoURL,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (newName != null) updates['groupName'] = newName;
      if (newPhotoURL != null) updates['groupPhotoURL'] = newPhotoURL;

      await _firestore.collection('groups').doc(groupId).update(updates);
      return 'success';
    } catch (e) {
      return e.toString();
    }
  }

  // Make user as a admin
  Future<String> makeAdmin({
    required String groupId,
    required String userId,
    required String userName,
  }) async {
    try {
      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups').doc(groupId);

      batch.update(groupRef, {
        'admins': FieldValue.arrayUnion([userId]),
      });

      // System message
      final messageId = _firestore.collection('groupMessages').doc().id;
      batch.set(_firestore.collection('groupMessages').doc(messageId), {
        'messageId': messageId,
        'groupId': groupId,
        'senderId': 'system',
        'senderName': 'System',
        'message': '$userName is now an admin',
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'system',
      });

      await batch.commit();
      return 'success';
    } catch (e) {
      return e.toString();
    }
  }

  // Remove admin
  Future<String> removeAdmin({
    required String groupId,
    required String userId,
    required String userName,
  }) async {
    try {
      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups').doc(groupId);

      batch.update(groupRef, {
        'admins': FieldValue.arrayRemove([userId]),
      });

      // System message
      final messageId = _firestore.collection('groupMessages').doc().id;
      batch.set(_firestore.collection('groupMessages').doc(messageId), {
        'messageId': messageId,
        'groupId': groupId,
        'senderId': 'system',
        'senderName': 'System',
        'message': '$userName is no longer an admin',
        'timestamp': FieldValue.serverTimestamp(),
        'type': 'system',
      });

      await batch.commit();
      return 'success';
    } catch (e) {
      return e.toString();
    }
  }

  // Toggle anyone can edit info
  Future<String> toggleGroupEditPermission(String groupId, bool allow) async {
    try {
      await _firestore.collection('groups').doc(groupId).update({
        'anyoneCanEditInfo': allow,
      });
      return 'success';
    } catch (e) {
      return e.toString();
    }
  }

  // Group typing status
  Future<void> setGroupTypingStatus(String groupId, bool isTyping) async {
    if (currentUserId.isEmpty) return;

    try {
      // Check if group exists first
      final groupDoc = await _firestore.collection('groups').doc(groupId).get();

      if (!groupDoc.exists) {
        print('Group $groupId not found, skipping typing status update');
        return;
      }

      await _firestore.collection('groups').doc(groupId).update({
        'typing.$currentUserId': isTyping,
        'typingTimestamp.$currentUserId': FieldValue.serverTimestamp(),
      });

      if (!isTyping) {
        Future.delayed(const Duration(seconds: 1), () async {
          try {
            // Check again before cleanup
            final doc =
                await _firestore.collection('groups').doc(groupId).get();
            if (doc.exists) {
              await _firestore.collection('groups').doc(groupId).update({
                'typing.$currentUserId': false,
              });
            }
          } catch (e) {
            // Ignore
          }
        });
      }
    } catch (e) {
      print('Error updating group typing status: $e');
    }
  }

  // Get group typing status
  Stream<Map<String, bool>> getGroupTypingStatus(String groupId) {
    return _firestore.collection('groups').doc(groupId).snapshots().map((doc) {
      if (!doc.exists) return <String, bool>{};

      final data = doc.data() as Map<String, dynamic>;
      final typing = data['typing'] as Map<String, dynamic>? ?? {};
      final typingTimestamp =
          data['typingTimestamp'] as Map<String, dynamic>? ?? {};

      final result = <String, bool>{};
      final now = DateTime.now();

      typing.forEach((userId, isTyping) {
        if (userId != currentUserId) {
          final timestamp = typingTimestamp[userId];
          if (timestamp != null && isTyping == true) {
            final typingTime = (timestamp as Timestamp).toDate();
            final isRecent = now.difference(typingTime).inSeconds < 5;
            result[userId] = isRecent;
          } else {
            result[userId] = false;
          }
        }
      });

      return result;
    });
  }

  // Send group image message
 
  // -------------------- GROUP CHAT MEDIA MESSAGES --------------------

  /// Sends a group media message after its upload to Cloudflare R2.
  ///
  /// Only picture messages are supported.
  Future<String> sendGroupMediaMessage({
    required String groupId,
    required String mediaUrl,
    required String mediaCategory,
    String? caption,
    String? mediaKey,
    String? fileName,
    String? contentType,
    int? fileSize,
    int? expiresAtMs,
  }) async {
    try {
      final currentUser = _auth.currentUser;

      if (currentUser == null) {
        return 'You must sign in before sending media.';
      }

      const supportedCategories = {'image'};

      if (!supportedCategories.contains(mediaCategory)) {
        return 'Unsupported media category.';
      }

      if (mediaUrl.trim().isEmpty) {
        return 'The media URL is empty.';
      }

      final groupRef = _firestore.collection('groups').doc(groupId);
      final groupDoc = await groupRef.get();

      if (!groupDoc.exists) {
        return 'Group not found';
      }

      final groupData = groupDoc.data()!;
      final members = List<String>.from(groupData['members'] ?? []);

      if (!members.contains(currentUser.uid)) {
        return 'You are not a member of this group.';
      }

      final userDoc = await _firestore
          .collection('users')
          .doc(currentUser.uid)
          .get();

      final senderPhotoURL = userDoc.data()?['photoURL'];

      final messageId =
          _firestore.collection('groupMessages').doc().id;

      final trimmedCaption = caption?.trim() ?? '';

      const defaultLabels = <String, String>{'image': '📷 Photo'};

      final lastMessage = trimmedCaption.isNotEmpty
          ? trimmedCaption
          : defaultLabels[mediaCategory]!;

      final messageData = <String, dynamic>{
        'messageId': messageId,
        'groupId': groupId,
        'senderId': currentUser.uid,
        'senderName': currentUser.displayName ?? 'User',
        'senderPhotoURL': senderPhotoURL,
        'message': caption ?? '',
        'mediaUrl': mediaUrl,
        'timestamp': FieldValue.serverTimestamp(),
        'type': mediaCategory,
        'mediaCategory': mediaCategory,
      };

      // Keep imageUrl for compatibility with the existing image UI.
      if (mediaCategory == 'image') {
        messageData['imageUrl'] = mediaUrl;
      }

      if (mediaKey != null && mediaKey.isNotEmpty) {
        messageData['mediaKey'] = mediaKey;
      }

      if (fileName != null && fileName.isNotEmpty) {
        messageData['fileName'] = fileName;
      }

      if (contentType != null && contentType.isNotEmpty) {
        messageData['contentType'] = contentType;
      }

      if (fileSize != null) {
        messageData['fileSize'] = fileSize;
      }

      if (expiresAtMs != null) {
        messageData['expiresAtMs'] = expiresAtMs;
      }

      final batch = _firestore.batch();

      batch.set(
        _firestore.collection('groupMessages').doc(messageId),
        messageData,
      );

      final unreadUpdates = <String, dynamic>{
        'lastMessage': lastMessage,
        'lastMessageTime': FieldValue.serverTimestamp(),
      };

      for (final memberId in members) {
        unreadUpdates['unreadCount.$memberId'] =
            memberId == currentUser.uid
                ? 0
                : FieldValue.increment(1);
      }

      batch.update(groupRef, unreadUpdates);

      await batch.commit();

      await sendGroupMessageNotification(
        groupId: groupId,
        message: lastMessage,
        senderName: currentUser.displayName ?? 'User',
        members: members,
        groupName: groupData['groupName'] ?? 'Group',
      );

      return 'success';
    } catch (e) {
      print('Error sending group media: $e');
      return e.toString();
    }
  }

  /// Uploads a selected file to Cloudflare R2 and sends it to the group.
  Future<String> sendGroupMediaWithUpload({
    required String groupId,
    required XFile file,
    required String mediaCategory,
    String? caption,
  }) async {
    try {
      final result = await CloudflareMediaService.instance.uploadFile(
        file,
        purpose: 'group',
        groupId: groupId,
        category: mediaCategory,
      );

      final mediaUrl = result['url'];
      final mediaKey = result['key'];

      if (mediaUrl is! String || mediaUrl.isEmpty) {
        return 'Cloudflare did not return a media URL.';
      }

      if (mediaKey is! String || mediaKey.isEmpty) {
        return 'Cloudflare did not return a media storage key.';
      }

      final rawExpiry = result['expiresAtMs'];
      final expiresAtMs =
          rawExpiry is num ? rawExpiry.toInt() : null;

      return await sendGroupMediaMessage(
        groupId: groupId,
        mediaUrl: mediaUrl,
        mediaCategory: mediaCategory,
        caption: caption,
        mediaKey: mediaKey,
        fileName: file.name,
        contentType: file.mimeType,
        fileSize: await file.length(),
        expiresAtMs: expiresAtMs,
      );
    } catch (e) {
      print('Error uploading or sending group media: $e');
      return e.toString();
    }
  }

  /// Backward-compatible method for existing group image messages.
  Future<String> sendGroupImageMessage({
    required String groupId,
    required String imageUrl,
    String? caption,
    String? mediaKey,
    String? fileName,
    String? contentType,
    int? fileSize,
    int? expiresAtMs,
    String mediaCategory = 'image',
  }) async {
    return sendGroupMediaMessage(
      groupId: groupId,
      mediaUrl: imageUrl,
      mediaCategory: mediaCategory,
      caption: caption,
      mediaKey: mediaKey,
      fileName: fileName,
      contentType: contentType,
      fileSize: fileSize,
      expiresAtMs: expiresAtMs,
    );
  }

  /// Backward-compatible upload method for existing image-picker calls.
  Future<String> sendGroupImageWithUpload({
    required String groupId,
    required XFile imageFile,
    String? caption,
  }) async {
    return sendGroupMediaWithUpload(
      groupId: groupId,
      file: imageFile,
      mediaCategory: 'image',
      caption: caption,
    );
  }

  // to delete a group (admin only)
  // Enhanced delete with storage cleanup
  Future<String> deleteGroup(String groupId) async {
    try {
      final batch = _firestore.batch();

      // Delete the group document
      batch.delete(_firestore.collection('groups').doc(groupId));

      // Get all group messages
      final messages = await _firestore
          .collection('groupMessages')
          .where('groupId', isEqualTo: groupId)
          .get();

      // Delete all messages and collect image URLs
      final imageUrls = <String>[];
      for (final doc in messages.docs) {
        final data = doc.data();
        if (data['imageUrl'] != null) {
          imageUrls.add(data['imageUrl'] as String);
        }
        batch.delete(doc.reference);
      }

      // Commit batch
      await batch.commit();

      // Delete images from storage (do this after batch to avoid rollback issues)
      try {
        // Delete group profile image
        final groupDoc =
            await _firestore.collection('groups').doc(groupId).get();
        if (groupDoc.exists && groupDoc.data()?['groupPhotoURL'] != null) {
          final photoRef = FirebaseStorage.instance.refFromURL(
            groupDoc.data()!['groupPhotoURL'],
          );
          await photoRef.delete();
        }

        // Delete all message images
        for (final imageUrl in imageUrls) {
          try {
            final imageRef = FirebaseStorage.instance.refFromURL(imageUrl);
            await imageRef.delete();
          } catch (e) {
            print('Error deleting image: $e');
            // Continue even if some images fail to delete
          }
        }
      } catch (e) {
        print('Error deleting storage files: $e');
        // Don't fail the whole operation if storage deletion fails
      }

      return 'success';
    } catch (e) {
      print('Error deleting group: $e');
      return e.toString();
    }
  }

  // ✅ Mark messages as read when user opens the chat
  Future<String> markGroupMessagesAsRead(String groupId) async {
    if (currentUserId.isEmpty) return 'No user';

    try {
      await _firestore.collection('groups').doc(groupId).update({
        'unreadCount.$currentUserId': 0,
      });
      return 'success';
    } catch (e) {
      print('Error marking messages as read: $e');
      return e.toString();
    }
  }
}
