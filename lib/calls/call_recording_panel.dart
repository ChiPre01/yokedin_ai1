import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/models/meeting_minutes_model.dart';
import 'package:yoked_in/ai/services/groq_service.dart';
import 'package:yoked_in/calls/call_meeting_compiler.dart';
import 'package:yoked_in/calls/call_recording_models.dart';
import 'package:yoked_in/calls/call_recording_repository.dart';
import 'package:yoked_in/calls/call_transcription_pipeline.dart';

/// Shows the latest recorded call for a conversation and drives the
/// transcript → minutes workflow.
class CallRecordingPanel extends ConsumerStatefulWidget {
  const CallRecordingPanel({
    super.key,
    required this.conversationId,
    required this.conversationType,
    required this.conversationTitle,
    required this.onMinuteReady,
  });

  final String conversationId;
  final String conversationType;
  final String conversationTitle;
  final void Function(MeetingMinutesModel minute) onMinuteReady;

  @override
  ConsumerState<CallRecordingPanel> createState() =>
      _CallRecordingPanelState();
}

class _CallRecordingPanelState extends ConsumerState<CallRecordingPanel> {
  final CallRecordingRepository _repository = CallRecordingRepository();
  final CallTranscriptionPipeline _pipeline = CallTranscriptionPipeline();

  CallRecordingSession? _session;
  bool _loading = true;
  bool _busy = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  Future<void> _loadSession() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final sessions = uid.isEmpty
          ? const <CallRecordingSession>[]
          : await _repository.sessionsForConversation(
              conversationId: widget.conversationId,
              conversationType: widget.conversationType,
              ownerUid: uid,
            );
      if (!mounted) return;
      setState(() {
        _session = sessions.isEmpty ? null : sessions.first;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load recorded calls. Please try again.';
      });
    }
  }

  Future<void> _transcribe() async {
    final session = _session;
    if (session == null || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
      _status = 'Preparing the recording…';
    });

    try {
      final result = await _pipeline.run(
        sessionId: session.id,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _status = progress.total > 0 && progress.total != 1
                ? '${progress.label} (${progress.completed + 1}/${progress.total})'
                : progress.label;
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = result.audioDeleted
            ? 'Transcript saved in Firestore. The audio has been deleted.'
            : 'Transcript saved in Firestore. Some audio could not be deleted '
                'and will expire automatically.';
      });

      await _loadSession();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
        _error = error is CallPipelineException
            ? error.message
            : 'The recording could not be transcribed. '
                'The audio has been kept so you can try again.';
      });
      await _loadSession();
    }
  }

  Future<void> _generateMinutes() async {
    final session = _session;
    if (session == null || _busy) return;

    final meetingId = (session.meetingId ?? '').trim();
    final transcript = session.transcriptText?.trim() ?? '';
    if (meetingId.isEmpty && transcript.isEmpty) return;

    setState(() {
      _busy = true;
      _error = null;
      _status = meetingId.isEmpty
          ? 'Generating minutes from the saved transcript…'
          : 'Combining every participant\'s transcript…';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      final uid = user?.uid ?? '';

      // A meeting is recorded by several devices. Each one transcribes its own
      // audio and publishes the text to the meeting, so the minutes are built
      // here from every contributed part instead of this phone's audio only.
      final minute = meetingId.isNotEmpty
          ? await CallMeetingCompiler(groq: ref.read(groqServiceProvider))
              .compile(
              meetingId: meetingId,
              uid: uid,
              conversationId: widget.conversationId,
              conversationType: widget.conversationType,
              conversationTitle: widget.conversationTitle,
              onProgress: (label) {
                if (!mounted) return;
                setState(() => _status = label);
              },
            )
          : await ref.read(groqServiceProvider).generateAndSaveMeetingMinutes(
                conversationId: widget.conversationId,
                conversationType: widget.conversationType,
                conversationTitle: widget.conversationTitle,
                transcript: _transcriptForMinutes(transcript),
                participants: uid.isEmpty ? const [] : [uid],
                participantNames: uid.isEmpty
                    ? const {}
                    : {uid: user?.displayName ?? 'You'},
                durationSeconds: session.durationSeconds,
              );

      // Remember which minutes document came from this transcript so the
      // button becomes an explicit regeneration instead of creating a
      // duplicate on an accidental second tap.
      try {
        await _repository.updateSession(session.id, {'minuteId': minute.id});
      } catch (_) {
        // The minutes are already saved; this flag is only a UI guard.
      }

      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Minutes generated and saved.';
      });
      widget.onMinuteReady(minute);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
        _error = error is AiServiceException
            ? error.message
            : 'The minutes could not be generated. Please try again.';
      });
    }
  }

  /// Adds the capture context before the transcript reaches the AI.
  ///
  /// Only used for a recording that is not part of a shared meeting: that
  /// transcript contains this device's microphone only, so the minutes prompt
  /// must not be led to believe every participant was captured.
  String _transcriptForMinutes(String transcript) {
    final owner = FirebaseAuth.instance.currentUser?.displayName ?? 'the owner';
    return 'Context: this transcript was captured from $owner\'s device '
        'microphone only. Speech from other participants may be missing or '
        'faint, and speakers are not identified in the transcript.\n\n'
        '$transcript';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('Checking for a recorded call…',
                style: TextStyle(fontSize: 12.5)),
          ],
        ),
      );
    }

    final session = _session;
    if (session == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.graphic_eq, size: 18, color: Colors.grey.shade600),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'No recorded call yet. Start the AI listener from inside a '
                'call to record it, then transcribe it here.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          ],
        ),
      );
    }

    final canTranscribe = !session.hasTranscript;
    final canGenerateMinutes = session.hasTranscript;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mic_none, size: 18, color: Colors.blue.shade800),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Recorded call · ${_formatDateTime(session.startedAt)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${_formatDuration(session.durationSeconds)} · '
            '${session.chunkCount} part${session.chunkCount == 1 ? '' : 's'} · '
            '${_stateLabel(session)}'
            '${(session.meetingId ?? '').isNotEmpty ? ' · shared meeting' : ''}',
            style: TextStyle(fontSize: 12, color: Colors.blue.shade900),
          ),
          if ((session.error ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              session.error!,
              style: const TextStyle(fontSize: 11.5, color: Colors.red),
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (_busy) ...[
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    _status!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (canTranscribe)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _transcribe,
                    icon: const Icon(Icons.notes, size: 18),
                    label: const Text('Transcribe recording'),
                  ),
                ),
              if (canGenerateMinutes)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _generateMinutes,
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: Text(
                      session.minuteId == null
                          ? 'Minutes from transcript'
                          : 'Regenerate minutes',
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _stateLabel(CallRecordingSession session) {
    switch (session.state) {
      case CallRecordingState.recording:
        return 'recording in progress';
      case CallRecordingState.completed:
        return 'audio kept, not transcribed';
      case CallRecordingState.transcribing:
        return 'transcribing';
      case CallRecordingState.transcribed:
        return 'transcript saved, audio pending deletion';
      case CallRecordingState.audioDeleted:
        return 'transcript saved, audio deleted';
      case CallRecordingState.failed:
        return 'needs a retry';
    }
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return 'no duration recorded';
    final minutes = seconds ~/ 60;
    final remaining = seconds % 60;
    if (minutes == 0) return '${remaining}s';
    return '${minutes}m ${remaining}s';
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();

    String two(int number) => number.toString().padLeft(2, '0');

    return '${two(local.day)}/${two(local.month)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
