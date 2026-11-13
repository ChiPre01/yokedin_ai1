import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yoked_in/calls/call_recording_models.dart';
import 'package:yoked_in/calls/call_recording_repository.dart';
import 'package:yoked_in/calls/recording_file_store.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

/// Records this device's own microphone during a ZEGO call.
///
/// What the SDK records: `startRecordingCapturedData` captures the locally
/// captured audio of this device, not the mixed audio of the room. A full
/// meeting transcript therefore needs every participant who wants their own
/// speech transcribed to turn the listener on; the app never claims to capture
/// other people's microphones.
///
/// The recording is rotated every [segmentDuration] so every part is a
/// complete, independently playable file well below the 25 MB upload and
/// speech-to-text ceiling. Rotating (rather than cutting a finished file)
/// means no audio frame is ever split and each part keeps valid container
/// headers.
class CallListenerService {
  CallListenerService._();

  static final CallListenerService instance = CallListenerService._();

  /// Each part covers at most this much audio. At ZEGO's AAC bitrate this is a
  /// few MB, far below the 25 MB per-file limit, and it leaves headroom for
  /// higher-bitrate devices.
  static const Duration segmentDuration = Duration(minutes: 15);

  /// Hard ceiling for one part, matching the Worker and Groq limits.
  static const int maxSegmentBytes = 25 * 1024 * 1024;

  /// Aggressive ANS is meant for speech-only calls: it removes continuous
  /// noise (fans, traffic, rain) hard while keeping voices intelligible.
  /// The `AI*` modes exist in the SDK but ZEGO asks you to contact support
  /// before enabling them on a project, so they are not used here.
  static const ZegoANSMode _ansMode = ZegoANSMode.Aggressive;

  /// The engine refuses to record until it is publishing, and the prebuilt UI
  /// publishes shortly after joining the room. These are the delays used to
  /// retry a start that came too early.
  static const List<Duration> _startRetryDelays = [
    Duration.zero,
    Duration(milliseconds: 1200),
    Duration(milliseconds: 2600),
  ];

  final CallRecordingRepository _repository = CallRecordingRepository();
  final RecordingFileStore _store = createRecordingFileStore();

  /// False on platforms where a recording file cannot be written (web).
  bool get isSupported => _store.isSupported;

  /// Tracks whether recording is active so the in-call button can rebuild.
  final ValueNotifier<bool> recordingNotifier = ValueNotifier<bool>(false);

  bool _isRecording = false;
  String? _sessionId;
  int _nextChunkIndex = 0;
  String? _segmentPath;
  DateTime? _segmentStartedAt;
  DateTime? _sessionStartedAt;
  int _chunkCount = 0;
  Timer? _rotationTimer;

  /// Shared meeting this device contributes to, when the call was started from
  /// a chat. Parts are stamped on the meeting timeline so every participant's
  /// audio can be merged into one transcript.
  int? _meetingStartedAtMs;
  int _clockOffsetMs = 0;
  String? _speakerUid;
  String? _speakerName;

  /// Serialises rotation and stop so two engine calls never overlap.
  Future<void> _queue = Future<void>.value();

  bool get isRecording => _isRecording;

  /// Session id of the current or most recent recording.
  String? get sessionId => _sessionId;

  /// Enables noise suppression on the local audio path.
  ///
  /// Called once after the call service is initialised (so the setting applies
  /// before the first call publishes) and again when a call screen is built.
  Future<void> primeNoiseSuppression() async {
    final engine = ZegoExpressEngine.instance;
    try {
      await engine.enableANS(true);
      await engine.setANSMode(_ansMode);
      await engine.enableTransientANS(true);
      debugPrint('Call listener: ANS enabled ($_ansMode).');
    } catch (error) {
      debugPrint('Call listener: could not configure noise suppression: $error');
    }
  }

  /// Starts a new recording session for [conversation].
  ///
  /// Returns true when the first part is actually being written. A false
  /// result means nothing was recorded and no session is left behind.
  Future<bool> startRecording({
    required String callId,
    required CallConversationInfo conversation,
    required String ownerUid,
    required String ownerName,
    String? meetingId,
    int? meetingStartedAtMs,
    int clockOffsetMs = 0,
  }) async {
    if (_isRecording) return true;
    if (!_store.isSupported) {
      debugPrint('Call listener: recording is not supported on this platform.');
      return false;
    }

    final String sessionId;
    try {
      sessionId = await _repository.createSession(
        callId: callId,
        conversationId: conversation.conversationId,
        conversationType: conversation.conversationType,
        ownerUid: ownerUid,
        ownerName: ownerName,
        startedAt: DateTime.now(),
        meetingId: meetingId,
        speakerUid: ownerUid,
        speakerName: ownerName,
      );
    } catch (error) {
      debugPrint('Call listener: could not create the recording session.');
      return false;
    }

    _sessionId = sessionId;
    _sessionStartedAt = DateTime.now();
    _nextChunkIndex = 0;
    _chunkCount = 0;
    _meetingStartedAtMs = meetingStartedAtMs;
    _clockOffsetMs = clockOffsetMs;
    _speakerUid = ownerUid;
    _speakerName = ownerName;

    final started = await _beginSegment();
    if (!started) {
      await _repository.updateSession(sessionId, {
        'state': callRecordingStateToName(CallRecordingState.failed),
        'error': 'The recording could not start on this device.',
      });
      return false;
    }

    _isRecording = true;
    recordingNotifier.value = true;
    _rotationTimer =
        Timer.periodic(segmentDuration, (_) => _enqueue(_rotateSegment));
    return true;
  }

  /// Stops recording, finalises the last part and returns the session id.
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;

    _isRecording = false;
    recordingNotifier.value = false;
    _rotationTimer?.cancel();
    _rotationTimer = null;

    await (_queue = _queue.then((_) => _finaliseSegment()));

    final sessionId = _sessionId;
    final startedAt = _sessionStartedAt;
    _segmentPath = null;
    _segmentStartedAt = null;
    _meetingStartedAtMs = null;
    _clockOffsetMs = 0;

    if (sessionId == null) return null;

    final durationSeconds = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inSeconds;

    try {
      await _repository.updateSession(sessionId, {
        'state': callRecordingStateToName(CallRecordingState.completed),
        'endedAt': DateTime.now(),
        'durationSeconds': durationSeconds < 1 ? 1 : durationSeconds,
        'chunkCount': _chunkCount,
      });
    } catch (error) {
      debugPrint('Call listener: could not close the recording session.');
    }

    return sessionId;
  }

  /// Deletes a local recording part once its transcript is safely stored.
  Future<bool> deleteLocalPart(String path) => _store.delete(path);

  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) => task()).catchError((Object error) {
      debugPrint('Call listener: background recording task failed.');
    });
  }

  Future<void> _rotateSegment() async {
    if (!_isRecording) return;

    await _finaliseSegment();
    if (!_isRecording) return;

    _nextChunkIndex += 1;
    final started = await _beginSegment();
    if (!started) {
      _isRecording = false;
      recordingNotifier.value = false;
      _rotationTimer?.cancel();
      _rotationTimer = null;
      debugPrint('Call listener: could not continue recording.');
    }
  }

  Future<bool> _beginSegment() async {
    // ZEGO local recording accepts .mp4, .flv and .aac, and only .mp4 is a
    // container the speech-to-text service accepts. Pure audio is documented
    // as AAC, so an audio-only MP4 is tried first; audio+video MP4 (still one
    // AAC track) is the documented fallback if the SDK refuses audio only.
    final path = await _store.preparePartPath(
      _sessionId ?? 'session',
      _nextChunkIndex,
    );
    if (path == null) return false;

    for (final type in const [
      ZegoDataRecordType.OnlyAudio,
      ZegoDataRecordType.AudioAndVideo,
    ]) {
      if (await _tryStartRecording(path, type)) {
        _segmentPath = path;
        _segmentStartedAt = DateTime.now();
        debugPrint('Call listener: recording part $_nextChunkIndex started.');
        return true;
      }
    }

    return false;
  }

  Future<bool> _tryStartRecording(
    String path,
    ZegoDataRecordType type,
  ) async {
    final engine = ZegoExpressEngine.instance;

    for (final delay in _startRetryDelays) {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }

      try {
        await engine.startRecordingCapturedData(
          ZegoDataRecordConfig(path, type),
          channel: ZegoPublishChannel.Main,
        );
      } catch (error) {
        debugPrint('Call listener: startRecording failed on one attempt.');
        continue;
      }

      // The SDK creates the file as soon as recording really begins, so a
      // missing file means the call was not publishing yet.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (await _store.exists(path) && await _store.sizeOf(path) > 0) {
        return true;
      }
    }

    return false;
  }

  Future<void> _finaliseSegment() async {
    final path = _segmentPath;
    final startedAt = _segmentStartedAt;
    if (path == null) return;

    _segmentPath = null;
    _segmentStartedAt = null;

    try {
      await ZegoExpressEngine.instance.stopRecordingCapturedData(
        channel: ZegoPublishChannel.Main,
      );
    } catch (error) {
      debugPrint('Call listener: stopRecording failed.');
    }

    final sizeBytes = await _settledLength(path);
    if (sizeBytes <= 0) {
      await deleteLocalPart(path);
      return;
    }

    final durationMs = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inMilliseconds;

    // Where this part sits on the meeting timeline. Device clocks differ, so
    // the local start is corrected by the offset measured against Firestore's
    // server clock before the recording started.
    final startOffsetMs =
        startedAt == null || _meetingStartedAtMs == null
            ? 0
            : (startedAt.millisecondsSinceEpoch + _clockOffsetMs) -
                _meetingStartedAtMs!;

    final chunk = CallRecordingChunk(
      chunkId: 'part_${_nextChunkIndex.toString().padLeft(4, '0')}',
      index: _nextChunkIndex,
      sizeBytes: sizeBytes,
      durationMs: durationMs,
      startOffsetMs: startOffsetMs < 0 ? 0 : startOffsetMs,
      speakerUid: _speakerUid,
      speakerName: _speakerName,
      state: sizeBytes > maxSegmentBytes
          ? CallChunkState.tooLarge
          : CallChunkState.local,
      localPath: path,
      error: sizeBytes > maxSegmentBytes
          ? 'This recording part is larger than 25 MB and cannot be uploaded.'
          : null,
    );

    final sessionId = _sessionId;
    if (sessionId == null) return;

    try {
      await _repository.saveChunk(sessionId, chunk);
      _chunkCount += 1;
      await _repository.updateSession(sessionId, {'chunkCount': _chunkCount});
    } catch (error) {
      debugPrint('Call listener: could not store a recording part.');
    }
  }

  /// The SDK finalises the file slightly after [stopRecordingCapturedData], so
  /// wait for its size to settle before reporting it.
  Future<int> _settledLength(String path) async {
    var previous = -1;
    for (var attempt = 0; attempt < 12; attempt++) {
      final length = await _store.sizeOf(path);
      if (length <= 0) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      if (length == previous) return length;
      previous = length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return previous > 0 ? previous : 0;
  }
}
