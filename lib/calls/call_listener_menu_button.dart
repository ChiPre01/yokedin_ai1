import 'package:flutter/material.dart';
import 'package:yoked_in/calls/call_listener_service.dart';
import 'package:yoked_in/calls/call_meeting_coordinator.dart';
import 'package:yoked_in/calls/call_recording_models.dart';

/// In-call menu button that starts and stops this participant's audio for the
/// call's shared meeting recording.
///
/// This is the consent surface for call capture: nothing is recorded until the
/// user taps it and confirms the notice, and the icon turns red while this
/// device is recording.
class CallListenerMenuButton extends StatelessWidget {
  const CallListenerMenuButton({
    super.key,
    required this.callId,
    this.conversation,
  });

  final String callId;

  /// Null when the call was not started from a chat, so the recording cannot be
  /// linked to minutes.
  final CallConversationInfo? conversation;

  @override
  Widget build(BuildContext context) {
    final service = CallListenerService.instance;

    return ValueListenableBuilder<bool>(
      valueListenable: service.recordingNotifier,
      builder: (context, isRecording, _) {
        return IconButton(
          tooltip: isRecording ? 'Stop AI listener' : 'Start AI listener',
          iconSize: 30,
          color: isRecording ? Colors.redAccent : Colors.white,
          icon: Icon(isRecording ? Icons.stop_circle : Icons.graphic_eq),
          onPressed: () => _onPressed(context, isRecording),
        );
      },
    );
  }

  Future<void> _onPressed(BuildContext context, bool isRecording) async {
    final coordinator = CallMeetingCoordinator.instance;
    final messenger = ScaffoldMessenger.maybeOf(context);

    void notify(String message) {
      messenger?.showSnackBar(SnackBar(content: Text(message)));
    }

    if (isRecording) {
      final sessionId = await coordinator.stopMine();
      notify(
        sessionId == null
            ? 'The AI listener stopped, but no audio was saved.'
            : 'Recording saved. Open this chat\'s Minutes sheet to transcribe it.',
      );
      return;
    }

    if (!CallListenerService.instance.isSupported) {
      notify('Call recording is not available on this device yet.');
      return;
    }

    if (conversation == null) {
      notify(
        'Start the call from a chat so AI can link the recording to minutes.',
      );
      return;
    }

    final agreed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Start AI listener?'),
        content: const Text(
          'This device will record your microphone for this call so AI can '
          'write the minutes afterwards. Everyone on the call should know they '
          'are being recorded. Other participants can add their own audio to '
          'the same minutes, and only one meeting recording runs at a time. '
          'The audio is deleted once the transcript has been saved, and at the '
          'latest 24 hours after the call.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Start recording'),
          ),
        ],
      ),
    );

    if (agreed != true) return;

    final result = await coordinator.startMeetingRecording();
    if (!context.mounted) return;

    switch (result.outcome) {
      case CallMeetingStartOutcome.recording:
        notify(
          'AI listener is recording this call. Every participant can add their '
          'own audio to the same minutes.',
        );
        break;
      case CallMeetingStartOutcome.ownedByOther:
        await _offerToAddAudio(
          context,
          result.holderName ?? 'another participant',
        );
        break;
      case CallMeetingStartOutcome.alreadyRecording:
        break;
      case CallMeetingStartOutcome.unsupported:
      case CallMeetingStartOutcome.notInCall:
      case CallMeetingStartOutcome.failed:
        notify(
          result.message ??
              'The AI listener could not start recording this call.',
        );
        break;
    }
  }

  /// Shown when another participant already started the meeting recording.
  ///
  /// The meeting keeps exactly one active recording, so this device does not
  /// start a second one; it offers to contribute its own microphone instead.
  Future<void> _offerToAddAudio(
    BuildContext context,
    String holderName,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);

    final addMine = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Meeting already being recorded'),
        content: Text(
          'Meeting currently recorded by $holderName.\n\n'
          'Only one meeting recording runs at a time. You can add your own '
          'microphone to that recording, so your words still appear in the '
          'minutes with your name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Add my audio'),
          ),
        ],
      ),
    );

    if (addMine != true) return;

    final result = await CallMeetingCoordinator.instance.addMyAudio();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          result.isRecording
              ? 'Your microphone is now part of this meeting recording.'
              : (result.message ?? 'Your audio could not be added.'),
        ),
      ),
    );
  }
}
