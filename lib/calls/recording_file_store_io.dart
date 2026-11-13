import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yoked_in/calls/recording_file_store_base.dart';

RecordingFileStore createRecordingFileStore() => const IoRecordingFileStore();

/// Native implementation: parts live in the app documents folder.
class IoRecordingFileStore implements RecordingFileStore {
  const IoRecordingFileStore();

  static const String _folderName = 'call_recordings';

  @override
  bool get isSupported => true;

  @override
  Future<String?> preparePartPath(String sessionId, int index) async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final directory = Directory('${base.path}/$_folderName/$sessionId');
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      return '${directory.path}/part_${index.toString().padLeft(4, '0')}.mp4';
    } catch (error) {
      debugPrint('Call recording: could not prepare the recording folder.');
      return null;
    }
  }

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<int> sizeOf(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<bool> delete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      return true;
    } catch (error) {
      debugPrint('Call recording: could not delete a local part.');
      return false;
    }
  }
}
