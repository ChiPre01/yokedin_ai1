/// File storage used by call recording.
///
/// Kept behind a conditional import so the web build never pulls in `dart:io`.
/// Browser builds report [isSupported] as false: ZEGO local data recording
/// writes to a filesystem path, which Flutter web cannot provide here.
abstract class RecordingFileStore {
  bool get isSupported;

  /// Absolute path for a new recording part, or null when unavailable.
  Future<String?> preparePartPath(String sessionId, int index);

  Future<bool> exists(String path);

  Future<int> sizeOf(String path);

  Future<bool> delete(String path);
}
