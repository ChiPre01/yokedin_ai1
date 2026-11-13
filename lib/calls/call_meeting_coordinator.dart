import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yoked_in/calls/call_listener_service.dart';
import 'package:yoked_in/calls/call_meeting_models.dart';
import 'package:yoked_in/calls/call_meeting_repository.dart';
import 'package:yoked_in/calls/call_recording_models.dart';

/// Result of trying to record a meeting from this device.
enum CallMeetingStartOutcome {
  recording,
  alreadyRecording,
  ownedByOther,
  unsupported,
  notInCall,
  failed,
}

class CallMeetingStartResult {
  const CallMeetingStartResult(
    this.outcome, {
    this.holderName,
    this.message,
  });

  final CallMeetingStartOutcome outcome;
  final String? holderName;
  final String? message;

  bool get isRecording => outcome == CallMeetingStartOutcome.recording;
}

/// Joins this device to the shared recording of the call it is in.
///
/// One call has one meeting document ([CallMeeting.meetingIdForCallId]) and one
/// active recorder slot. The recorder slot is what the "meeting currently
/// recorded by `<name>`" message reports; every other participant can still add
/// their own microphone as a contribution, which is what makes a transcript of
/// the whole meeting possible without one phone trying to hear the room.
///
/// The coordinator also owns the two cross-device alerts:
///  * somebody started recording this meeting - offer to add your audio;
///  * the recorder stopped or disconnected - offer to continue recording.
class CallMeetingCoordinator {
  CallMeetingCoordinator._();

  static final CallMeetingCoordinator instance = CallMeetingCoordinator._();

  static const Duration heartbeatInterval = Duration(seconds: 15);

  /// A recorder that has not sent a heartbeat for this long is treated as
  /// disconnected, so somebody else may take over.
  static const int staleRecorderMs = 45000;

  /// Set from `main.dart`; dialogs are shown on the root navigator so they
  /// appear above the ZEGO call page.
  GlobalKey<NavigatorState>? navigatorKey;

  CallMeetingRepository? _repository;
  CallMeetingRepository get _repositoryInstance =>
      _repository ??= CallMeetingRepository();

  final ValueNotifier<CallMeeting?> meetingNotifier =
      ValueNotifier<CallMeeting?>(null);

  CallConversationInfo? _conversation;
  String? _callId;
  String? _meetingId;
  String _uid = '';
  String _name = '';
  CallMeeting? _meeting;
  StreamSubscription<CallMeeting?>? _subscription;
  Timer? _heartbeatTimer;
  int _clockOffsetMs = 0;
  int _handledStopNoticeMs = 0;
  bool _invitePromptShown = false;
  bool _dialogVisible = false;

  bool get isAttached => _meetingId != null;
  String? get meetingId => _meetingId;
  CallConversationInfo? get conversation => _conversation;

  /// Starts watching the meeting for this call so alerts reach every
  /// participant, whether or not they record anything.
  Future<void> attach({
    required String callId,
    required CallConversationInfo? conversation,
    required String uid,
    required String name,
  }) async {
    if (conversation == null || uid.trim().isEmpty) return;

    final meetingId = CallMeeting.meetingIdForCallId(callId);
    if (_meetingId == meetingId && _uid == uid) return;

    if (_meetingId != null) {
      await detach(reason: 'left');
    }

    _callId = callId;
    _conversation = conversation;
    _uid = uid;
    _name = name.trim().isEmpty ? 'You' : name.trim();
    _meetingId = meetingId;
    _invitePromptShown = false;
    _handledStopNoticeMs = 0;

    _subscription = _repositoryInstance.watch(meetingId).listen(
      _handleMeeting,
      onError: (Object error) {
        debugPrint('Call meeting watch failed: $error');
      },
    );
  }

  /// Leaves the meeting: finalises this device's audio and, if this device was
  /// the active recorder, tells everyone that recording stopped.
  Future<void> detach({String reason = 'left'}) async {
    _subscription?.cancel();
    _subscription = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    final service = CallListenerService.instance;
    if (service.isRecording) {
      try {
        await service.stopRecording();
      } catch (error) {
        debugPrint('Call meeting detach could not stop the recording: $error');
      }
    }

    final meetingId = _meetingId;
    final uid = _uid;
    if (meetingId != null && uid.isNotEmpty) {
      try {
        await _repositoryInstance.release(
          meetingId: meetingId,
          uid: uid,
          name: _name,
          reason: reason,
        );
      } catch (error) {
        debugPrint('Call meeting detach could not release the recorder: $error');
      }
    }

    _meetingId = null;
    _callId = null;
    _conversation = null;
    _meeting = null;
    _uid = '';
    _name = '';
    _clockOffsetMs = 0;
    meetingNotifier.value = null;
  }

  /// Starts (or takes over) the meeting's recording from this device.
  Future<CallMeetingStartResult> startMeetingRecording() async {
    final service = CallListenerService.instance;
    final conversation = _conversation;
    final meetingId = _meetingId;
    final callId = _callId;

    if (conversation == null || meetingId == null || callId == null) {
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.notInCall,
        message: 'Start the call from a chat so AI can link the recording '
            'to minutes.',
      );
    }

    if (!service.isSupported) {
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.unsupported,
        message: 'Call recording is not available on this device yet.',
      );
    }

    if (service.isRecording) {
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.alreadyRecording,
      );
    }

    try {
      // Claim first: this is what creates the meeting document together with
      // its conversation identity. Writing participant data before the claim
      // created a document with no conversation id, and generating minutes
      // from it then failed with "A valid conversationId is required."
      final claim = await _repositoryInstance.claimRecorder(
        meetingId: meetingId,
        callId: callId,
        conversationId: conversation.conversationId,
        conversationType: conversation.conversationType,
        title: conversation.title,
        uid: _uid,
        name: _name,
      );

      final meeting = claim.meeting;
      if (!claim.granted) {
        return CallMeetingStartResult(
          CallMeetingStartOutcome.ownedByOther,
          holderName: claim.holderName ?? meeting?.activeRecorderName,
        );
      }

      // Safe now: the document exists, so this only adds clock data.
      _clockOffsetMs = await _repositoryInstance.measureServerOffsetMs(
        meetingId: meetingId,
        uid: _uid,
      );

      final started = await _startLocalRecording(
        conversation: conversation,
        meeting: meeting,
        meetingId: meetingId,
        callId: callId,
      );

      if (!started) {
        await _repositoryInstance.release(
          meetingId: meetingId,
          uid: _uid,
          name: _name,
          reason: 'failed',
        );
        return const CallMeetingStartResult(
          CallMeetingStartOutcome.failed,
          message: 'The AI listener could not start recording this call.',
        );
      }

      if (meeting != null) {
        _meeting = meeting;
        meetingNotifier.value = meeting;
      }
      _startHeartbeat(meetingId);
      return const CallMeetingStartResult(CallMeetingStartOutcome.recording);
    } catch (error) {
      debugPrint('Call meeting start failed: $error');
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.failed,
        message: 'This meeting could not be recorded. Please try again.',
      );
    }
  }

  /// Adds this device's microphone to a meeting somebody else is recording.
  ///
  /// This is the "add my audio" path: it does not take the recorder slot, so
  /// several participants can contribute without one meeting becoming two.
  Future<CallMeetingStartResult> addMyAudio() async {
    final service = CallListenerService.instance;
    final conversation = _conversation;
    final meetingId = _meetingId;
    final callId = _callId;

    if (conversation == null || meetingId == null || callId == null) {
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.notInCall,
        message: 'Start the call from a chat so AI can link the recording '
            'to minutes.',
      );
    }

    if (!service.isSupported) {
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.unsupported,
        message: 'Call recording is not available on this device yet.',
      );
    }

    if (service.isRecording) {
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.alreadyRecording,
      );
    }

    try {
      final meeting = _meeting ??
          await _repositoryInstance.load(meetingId);
      if (meeting == null) {
        return const CallMeetingStartResult(
          CallMeetingStartOutcome.failed,
          message: 'This meeting is no longer being recorded.',
        );
      }

      _clockOffsetMs = await _repositoryInstance.measureServerOffsetMs(
        meetingId: meetingId,
        uid: _uid,
      );

      final started = await _startLocalRecording(
        conversation: conversation,
        meeting: meeting,
        meetingId: meetingId,
        callId: callId,
      );

      if (!started) {
        return const CallMeetingStartResult(
          CallMeetingStartOutcome.failed,
          message: 'Your microphone could not be added to the recording.',
        );
      }

      await _repositoryInstance.upsertParticipant(
        meetingId: meetingId,
        uid: _uid,
        name: _name,
        state: 'recording',
      );
      return const CallMeetingStartResult(CallMeetingStartOutcome.recording);
    } catch (error) {
      debugPrint('Call meeting join failed: $error');
      return const CallMeetingStartResult(
        CallMeetingStartOutcome.failed,
        message: 'Your microphone could not be added to the recording.',
      );
    }
  }

  /// Stops this device's part and, when it held the recorder slot, marks the
  /// meeting stopped so everyone else is offered the "continue recording?"
  /// alert.
  Future<String?> stopMine() async {
    final service = CallListenerService.instance;
    final holder = _meeting?.activeRecorderUid ?? '';
    final wasActiveRecorder = holder == _uid && _uid.isNotEmpty;

    String? sessionId;
    if (service.isRecording) {
      sessionId = await service.stopRecording();
    }

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    final meetingId = _meetingId;
    if (meetingId != null && _uid.isNotEmpty) {
      try {
        await _repositoryInstance.release(
          meetingId: meetingId,
          uid: _uid,
          name: _name,
          reason: wasActiveRecorder ? 'stopped' : 'left',
        );
      } catch (error) {
        debugPrint('Call meeting stop could not be announced: $error');
      }
    }

    return sessionId;
  }

  Future<bool> _startLocalRecording({
    required CallConversationInfo conversation,
    required CallMeeting? meeting,
    required String meetingId,
    required String callId,
  }) async {
    final startedAtMs = meeting?.startedAtMs ??
        DateTime.now().millisecondsSinceEpoch;

    return CallListenerService.instance.startRecording(
      callId: callId,
      conversation: conversation,
      ownerUid: _uid,
      ownerName: _name,
      meetingId: meetingId,
      meetingStartedAtMs: startedAtMs,
      clockOffsetMs: _clockOffsetMs,
    );
  }

  void _startHeartbeat(String meetingId) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (!CallListenerService.instance.isRecording) {
        _heartbeatTimer?.cancel();
        _heartbeatTimer = null;
        return;
      }
      unawaited(
        _repositoryInstance
            .heartbeat(meetingId: meetingId, uid: _uid)
            .catchError((Object error) {
          debugPrint('Call meeting heartbeat failed: $error');
        }),
      );
    });
  }

  void _handleMeeting(CallMeeting? meeting) {
    _meeting = meeting;
    meetingNotifier.value = meeting;

    // A stop notice that happened before this call was joined is history, not
    // something to ask about.
    if (meeting != null && _handledStopNoticeMs == 0) {
      _handledStopNoticeMs = meeting.stopNoticeAtMs;
    }

    unawaited(_maybePrompt());
  }

  Future<void> _maybePrompt() async {
    if (_dialogVisible) return;

    final meeting = _meeting;
    final meetingId = _meetingId;
    if (meeting == null || meetingId == null || _uid.isEmpty) return;

    final service = CallListenerService.instance;
    if (service.isRecording) return;

    final context = navigatorKey?.currentContext;
    if (context == null || !context.mounted) return;

    final stopNotice = meeting.stopNoticeAtMs;
    if (!meeting.recordingActive &&
        stopNotice > 0 &&
        stopNotice != _handledStopNoticeMs) {
      _handledStopNoticeMs = stopNotice;
      await _showContinueDialog(context, meeting);
      return;
    }

    final holder = meeting.activeRecorderUid;
    final stale = meeting.recorderIsStale(
      DateTime.now().millisecondsSinceEpoch,
      thresholdMs: staleRecorderMs,
    );
    if (meeting.recordingActive &&
        holder.isNotEmpty &&
        holder != _uid &&
        !_invitePromptShown) {
      _invitePromptShown = true;
      await _showInviteDialog(context, meeting, holderIsStale: stale);
    }
  }

  Future<void> _showInviteDialog(
    BuildContext context,
    CallMeeting meeting, {
    required bool holderIsStale,
  }) async {
    _dialogVisible = true;
    final recorderName = meeting.activeRecorderName.isEmpty
        ? 'Another participant'
        : meeting.activeRecorderName;

    try {
      final addAudio = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Meeting is being recorded'),
          content: Text(
            '$recorderName is recording this meeting so AI can write the '
            'minutes.'
            '${holderIsStale ? ' Their device stopped responding, so you can '
                'take over the recording.' : ''}'
            '\n\nAdd your own audio so your words appear in the minutes? '
            'Each participant records only their own microphone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Add my audio'),
            ),
          ],
        ),
      );

      if (addAudio == true) {
        final result = await addMyAudio();
        _notify(
          result.isRecording
              ? 'Your microphone is now part of this meeting recording.'
              : (result.message ?? 'Your audio could not be added.'),
        );
      } else if (addAudio == false) {
        try {
          await _repositoryInstance.upsertParticipant(
            meetingId: meeting.id,
            uid: _uid,
            name: _name,
            state: 'declined',
          );
        } catch (error) {
          debugPrint('Call meeting decline could not be saved: $error');
        }
      }
    } finally {
      _dialogVisible = false;
    }
  }

  Future<void> _showContinueDialog(
    BuildContext context,
    CallMeeting meeting,
  ) async {
    _dialogVisible = true;

    final who = meeting.stoppedByName ?? 'The recorder';
    final reason = switch (meeting.stopReason) {
      'disconnected' => 'their connection dropped',
      'failed' => 'recording failed on their device',
      'left' => 'they left the call',
      _ => 'recording stopped',
    };

    try {
      final continueRecording = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Recording stopped'),
          content: Text(
            '$who is no longer recording this meeting ($reason).\n\n'
            'Continue recording from your device so the minutes still cover '
            'the rest of the meeting?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Continue recording'),
            ),
          ],
        ),
      );

      if (continueRecording == true) {
        final result = await startMeetingRecording();
        _notify(
          result.isRecording
              ? 'You are now recording this meeting.'
              : (result.message ??
                  (result.holderName != null
                      ? 'Meeting currently recorded by ${result.holderName}.'
                      : 'The recording could not continue.')),
        );
      } else if (continueRecording == false) {
        try {
          await _repositoryInstance.upsertParticipant(
            meetingId: meeting.id,
            uid: _uid,
            name: _name,
            state: 'declined',
          );
        } catch (error) {
          debugPrint('Call meeting decline could not be saved: $error');
        }
      }
    } finally {
      _dialogVisible = false;
    }
  }

  void _notify(String message) {
    final context = navigatorKey?.currentContext;
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
