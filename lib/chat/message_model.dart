
import 'package:cloud_firestore/cloud_firestore.dart';

class MessageModel {
  final String messageId;
  final String senderId;
  final String senderName;
  final String message;
  final DateTime? timestamp;
  final String type;
  final Map<String, DateTime>? readBy;

  // Existing image and call fields.
  final String? imageUrl;
  final String? callType;
  final String? callStatus;
  final int? duration;

  // New media fields.
  final String? mediaUrl;
  final String? mediaKey;
  final String? fileName;
  final String? contentType;
  final int? fileSize;
  final String? mediaCategory;
  final DateTime? expiresAt;

  MessageModel({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.message,
    this.timestamp,
    this.type = 'text',
    this.readBy,
    this.imageUrl,
    this.callType,
    this.callStatus,
    this.duration,
    this.mediaUrl,
    this.mediaKey,
    this.fileName,
    this.contentType,
    this.fileSize,
    this.mediaCategory,
    this.expiresAt,
  });

  static DateTime? _parseDateTime(dynamic value) {
    if (value is Timestamp) {
      return value.toDate();
    }

    if (value is DateTime) {
      return value;
    }

    // Cloudflare expiry values may be stored as milliseconds.
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }

    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }

    return null;
  }

  factory MessageModel.fromMap(Map<String, dynamic> map) {
    final rawReadBy = map['readBy'];
    final parsedReadBy = <String, DateTime>{};

    if (rawReadBy is Map) {
      rawReadBy.forEach((key, value) {
        final parsedDate = _parseDateTime(value);

        if (parsedDate != null) {
          parsedReadBy[key.toString()] = parsedDate;
        }
      });
    }

    final rawFileSize = map['fileSize'];

    return MessageModel(
      messageId: map['messageId']?.toString() ?? '',
      senderId: map['senderId']?.toString() ?? '',
      senderName: map['senderName']?.toString() ?? '',
      message: map['message']?.toString() ?? '',
      timestamp: _parseDateTime(map['timestamp']),
      type: map['type']?.toString() ?? 'text',
      readBy: parsedReadBy,
      imageUrl: map['imageUrl']?.toString(),
      callType: map['callType']?.toString(),
      callStatus: map['callStatus']?.toString(),
      duration: map['duration'] is num
          ? (map['duration'] as num).toInt()
          : null,
      mediaUrl: map['mediaUrl']?.toString() ??
          map['imageUrl']?.toString(),
      mediaKey: map['mediaKey']?.toString(),
      fileName: map['fileName']?.toString(),
      contentType: map['contentType']?.toString(),
      fileSize: rawFileSize is num ? rawFileSize.toInt() : null,
      mediaCategory: map['mediaCategory']?.toString(),
      expiresAt: _parseDateTime(
        map['expiresAt'] ?? map['expiresAtMs'],
      ),
    );
  }

  /// True when the media has passed its expiry time.
  /// Images and older messages without expiry metadata do not expire here.
  bool get isMediaExpired {
    if (mediaCategory == null || mediaCategory == 'image') {
      return false;
    }

    final expiry = expiresAt;

    if (expiry == null) {
      return false;
    }

    return !DateTime.now().isBefore(expiry);
  }

  /// Convert the message to a Firestore-compatible map.
  Map<String, dynamic> toMap() {
    return {
      'messageId': messageId,
      'senderId': senderId,
      'senderName': senderName,
      'message': message,
      'timestamp': timestamp != null
          ? Timestamp.fromDate(timestamp!)
          : FieldValue.serverTimestamp(),
      'type': type,
      'imageUrl': imageUrl,
      'readBy': readBy?.map(
        (key, value) => MapEntry(
          key,
          Timestamp.fromDate(value),
        ),
      ),
      if (callType != null) 'callType': callType,
      if (callStatus != null) 'callStatus': callStatus,
      if (duration != null) 'duration': duration,
      if (mediaUrl != null) 'mediaUrl': mediaUrl,
      if (mediaKey != null) 'mediaKey': mediaKey,
      if (fileName != null) 'fileName': fileName,
      if (contentType != null) 'contentType': contentType,
      if (fileSize != null) 'fileSize': fileSize,
      if (mediaCategory != null) 'mediaCategory': mediaCategory,
      if (expiresAt != null)
        'expiresAt': Timestamp.fromDate(expiresAt!),
    };
  }
}
