import 'package:flutter/foundation.dart';
import 'package:yoked_in/ai/config/ai_config.dart';
import 'package:yoked_in/ai/models/meeting_minutes_model.dart';
import 'package:yoked_in/ai/services/groq_service.dart';
import 'package:yoked_in/calls/call_meeting_models.dart';
import 'package:yoked_in/calls/call_meeting_repository.dart';

/// Combines every participant's contributed audio transcript into one timeline
/// and turns it into a single minutes document.
///
/// Each participant transcribes their own recording parts (the Worker only lets
/// a caller read its own media key), so this device only ever needs the saved
/// text from Firestore, never somebody else's audio.
class CallMeetingCompiler {
  CallMeetingCompiler({
    required GroqService groq,
    CallMeetingRepository? repository,
  })  : _groq = groq,
        _repository = repository ?? CallMeetingRepository();

  /// A meeting transcript can be long; the Worker condenses it in sections.
  /// Kept in sync with the endpoint ceiling in [AIConfig].
  static const int _maxTranscriptCharacters =
      AIConfig.maxCallTranscriptCharacters;

  final GroqService _groq;
  final CallMeetingRepository _repository;

  /// [conversationId], [conversationType] and [conversationTitle] are fallbacks
  /// for meetings recorded before their document stored that identity.
  Future<MeetingMinutesModel> compile({
    required String meetingId,
    required String uid,
    String? conversationId,
    String? conversationType,
    String? conversationTitle,
    void Function(String label)? onProgress,
  }) async {
    onProgress?.call('Reading every participant\'s transcript…');

    final meeting = await _repository.load(meetingId);
    if (meeting == null) {
      throw const CallMeetingException(
        'This meeting recording is no longer available.',
      );
    }

    final contributions = await _repository.loadContributions(meetingId);
    if (contributions.isEmpty) {
      throw const CallMeetingException(
        'No participant has saved a transcript for this meeting yet. '
        'Ask each participant to open the minutes sheet and transcribe their '
        'recording, then try again.',
      );
    }

    final transcript = buildTimeline(meeting, contributions);
    if (transcript.trim().isEmpty) {
      throw const CallMeetingException(
        'No speech was recognised in this meeting recording.',
      );
    }

    final names = <String, String>{
      for (final participant in meeting.participants.values)
        participant.uid: participant.name,
    };
    for (final contribution in contributions) {
      names.putIfAbsent(contribution.uid, () => contribution.name);
    }

    onProgress?.call('Writing the minutes from ${contributions.length} '
        'recording part(s)…');

    // The screen the minutes are generated from knows the conversation, and
    // it is authoritative: a meeting document written before its identity was
    // stored, or with a stale type, would otherwise send a group's minutes to
    // the private-chat permission check.
    final requestedConversationId = (conversationId ?? '').trim();
    final resolvedConversationId = requestedConversationId.isNotEmpty
        ? requestedConversationId
        : meeting.conversationId.trim();
    if (resolvedConversationId.isEmpty) {
      throw const CallMeetingException(
        'This meeting is not linked to a chat, so its minutes cannot be saved.',
      );
    }

    final requestedConversationType = (conversationType ?? '').trim();
    final resolvedConversationType = requestedConversationType.isNotEmpty
        ? requestedConversationType
        : (meeting.conversationType.trim().isNotEmpty
            ? meeting.conversationType.trim()
            : 'private');

    final resolvedTitle = meeting.title.trim().isNotEmpty
        ? meeting.title.trim()
        : ((conversationTitle ?? '').trim().isNotEmpty
            ? conversationTitle!.trim()
            : 'this call');

    final minute = await _groq.generateAndSaveMeetingMinutes(
      conversationId: resolvedConversationId,
      conversationType: resolvedConversationType,
      conversationTitle: resolvedTitle,
      transcript: transcript,
      participants: names.keys.toList(),
      participantNames: names,
      durationSeconds: durationSecondsOf(meeting, contributions),
      meetingId: meeting.id,
    );

    try {
      await _repository.markCompiled(
        meetingId: meetingId,
        minuteId: minute.id,
        uid: uid,
      );
    } catch (error) {
      debugPrint('Call meeting compiled flag could not be saved: $error');
    }

    return minute;
  }

  /// Meeting timeline length, from the first contribution to the last one.
  int durationSecondsOf(
    CallMeeting meeting,
    List<CallMeetingContribution> contributions,
  ) {
    var endMs = 0;
    for (final contribution in contributions) {
      final contributionEnd = contribution.startMs + contribution.durationMs;
      if (contributionEnd > endMs) endMs = contributionEnd;
    }
    if (endMs <= 0 || meeting.startedAtMs <= 0) return 0;
    final seconds = ((endMs - meeting.startedAtMs) / 1000).round();
    return seconds < 0 ? 0 : seconds;
  }

  /// Builds one speaker-labelled transcript from all contributions.
  ///
  /// Each line is labelled "`<name>` audio": the words came from that person's
  /// own device, which is strong evidence but not proof of who spoke, so the
  /// label makes the source explicit instead of claiming voice recognition.
  String buildTimeline(
    CallMeeting meeting,
    List<CallMeetingContribution> contributions,
  ) {
    final utterances = <_Utterance>[];

    for (final contribution in contributions) {
      final label = contribution.speakerLabel;
      if (contribution.segments.isEmpty) {
        final text = contribution.text.trim();
        if (text.isNotEmpty) {
          utterances.add(_Utterance(contribution.startMs, label, text));
        }
        continue;
      }

      for (final segment in contribution.segments) {
        final text = segment.text.trim();
        if (text.isEmpty) continue;
        final offsetMs = (segment.startSeconds * 1000).round();
        utterances.add(
          _Utterance(contribution.startMs + offsetMs, label, text),
        );
      }
    }

    if (utterances.isEmpty) return '';
    utterances.sort((a, b) => a.atMs.compareTo(b.atMs));

    final buffer = StringBuffer()
      ..writeln(
        'Context: this transcript was assembled from the phones of the '
        'participants in this meeting. Every line is labelled '
        '"<name> audio", which means the words were captured from that '
        'participant\'s own device. It is possible another person was near '
        'that device, so attribute statements to the person whose audio was '
        'captured rather than to a recognised voice. '
        'Lines appear in meeting order using each recording\'s start time.',
      )
      ..writeln();

    var currentLabel = '';
    final paragraph = <String>[];

    void flush() {
      if (paragraph.isEmpty) return;
      buffer.writeln('$currentLabel: ${paragraph.join(' ')}');
      paragraph.clear();
    }

    for (final utterance in utterances) {
      if (utterance.label != currentLabel) {
        flush();
        currentLabel = utterance.label;
        buffer.write('[${_timestamp(utterance.atMs)}] ');
      }
      if (paragraph.isNotEmpty) paragraph.add('');
      paragraph.add(utterance.text);
    }
    flush();

    final timeline = buffer.toString().trim();
    if (timeline.length <= _maxTranscriptCharacters) return timeline;

    // Keep whole lines: a transcript cut inside a sentence confuses the model.
    final lines = timeline.split('\n');
    final kept = StringBuffer();
    for (final line in lines) {
      if (kept.length + line.length + 1 > _maxTranscriptCharacters) break;
      kept.writeln(line);
    }
    kept.writeln(
      '[The transcript was shortened here because it reached the length '
      'limit; the remaining part of the meeting is not included.]',
    );
    return kept.toString().trim();
  }

  String _timestamp(int offsetMs) {
    final totalSeconds = offsetMs < 0 ? 0 : offsetMs ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}

class _Utterance {
  const _Utterance(this.atMs, this.label, this.text);

  final int atMs;
  final String label;
  final String text;
}

class CallMeetingException implements Exception {
  const CallMeetingException(this.message);

  final String message;

  @override
  String toString() => message;
}
