import 'package:yoked_in/calls/recording_file_store_base.dart';

RecordingFileStore createRecordingFileStore() => const WebRecordingFileStore();

/// Browser build: local call recording is not available, so the listener is
/// disabled instead of silently recording nothing.
class WebRecordingFileStore implements RecordingFileStore {
  const WebRecordingFileStore();

  @override
  bool get isSupported => false;

  @override
  Future<String?> preparePartPath(String sessionId, int index) async => null;

  @override
  Future<bool> exists(String path) async => false;

  @override
  Future<int> sizeOf(String path) async => 0;

  @override
  Future<bool> delete(String path) async => true;
}
