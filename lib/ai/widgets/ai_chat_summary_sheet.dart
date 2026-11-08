import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/models/meeting_minutes_model.dart';
import 'package:yoked_in/ai/screens/meeting_minutes_detail_screen.dart';
import 'package:yoked_in/ai/services/groq_service.dart';
import 'package:yoked_in/ai/services/meeting_minutes_service.dart';
import 'package:yoked_in/provider/chat_provider.dart';
import 'package:yoked_in/provider/group_chat_provider.dart';

/// Message types that carry readable text. Private chats persist `user`
/// (see ChatService.sendMessage); group chats persist `text`. Media, call and
/// system entries are excluded so they never reach the summariser.
const Set<String> _textMessageTypes = {'text', 'user'};

bool _isSummarizableMessage(String type, String message) {
  if (message.trim().isEmpty) return false;
  final normalized = type.trim().toLowerCase();
  // Legacy documents written before `type` existed are plain text.
  if (normalized.isEmpty) return true;
  return _textMessageTypes.contains(normalized);
}

void showChatSummaryBottomSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String conversationId,
  required String conversationTitle,
  required bool isGroup,
  String? otherUserId,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _ChatSummarySheet(
      conversationId: conversationId,
      conversationTitle: conversationTitle,
      isGroup: isGroup,
      otherUserId: otherUserId,
    ),
  );
}

class _ChatSummarySheet extends ConsumerStatefulWidget {
  final String conversationId;
  final String conversationTitle;
  final bool isGroup;
  final String? otherUserId;

  const _ChatSummarySheet({
    required this.conversationId,
    required this.conversationTitle,
    required this.isGroup,
    this.otherUserId,
  });

  @override
  ConsumerState<_ChatSummarySheet> createState() => _ChatSummarySheetState();
}

class _ChatSummarySheetState extends ConsumerState<_ChatSummarySheet> {
  bool _isLoading = true;
  String? _summary;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _generateSummary();
  }

  Future<void> _generateSummary() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _summary = null;
    });

    try {
      List<String> formattedMessages = [];

      if (widget.isGroup) {
        final messages = await ref
            .read(groupChatServiceProvider)
            .getGroupMessages(widget.conversationId, limit: 30)
            .first;
        formattedMessages = messages
            .where((m) => _isSummarizableMessage(m.type, m.message))
            .take(30)
            .toList()
            .reversed
            .map((m) => '${m.senderName}: ${m.message}')
            .toList();
      } else {
        final messages = await ref
            .read(chatServiceProvider)
            .getChatMessages(widget.conversationId)
            .first;
        formattedMessages = messages
            .where((m) => _isSummarizableMessage(m.type, m.message))
            .take(30)
            .toList()
            .reversed
            .map((m) => '${m.senderName}: ${m.message}')
            .toList();
      }

      if (formattedMessages.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = 'No recent text messages found to summarize.';
          });
        }
        return;
      }

      final summary = await ref.read(groqServiceProvider).summarizeChatMessages(
            messagesFormatted: formattedMessages,
            conversationTitle: widget.conversationTitle,
            conversationId: widget.conversationId,
            conversationType: widget.isGroup ? 'group' : 'private',
          );

      if (mounted) {
        setState(() {
          _summary = summary;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = _describeError(e);
        });
      }
    } finally {
      // Always release the spinner, no matter how the call ended.
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _describeError(Object error) {
    if (error is AiServiceException) return error.message;
    return error.toString().replaceFirst('Exception: ', '');
  }

  Future<void> _saveAsMinutes() async {
    if (_summary == null) return;

    try {
      final minute = MeetingMinutesModel(
        id: '',
        conversationId: widget.conversationId,
        conversationType: widget.isGroup ? 'group' : 'private',
        title: 'Chat Summary: ${widget.conversationTitle}',
        createdAt: DateTime.now(),
        durationSeconds: 0,
        participants: widget.otherUserId != null ? [widget.otherUserId!] : [],
        participantNames: widget.otherUserId != null
            ? {widget.otherUserId!: widget.conversationTitle}
            : {},
        summary: _summary!,
        keyDecisions: [],
        actionItems: [],
        rawTranscript: [],
      );

      final docId =
          await ref.read(meetingMinutesServiceProvider).addMeetingMinute(minute);

      if (mounted) {
        Navigator.pop(context); // close bottom sheet
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to Meeting Minutes!')),
        );
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MeetingMinutesDetailScreen(
              minute: MeetingMinutesModel(
                id: docId,
                conversationId: minute.conversationId,
                conversationType: minute.conversationType,
                title: minute.title,
                createdAt: minute.createdAt,
                durationSeconds: minute.durationSeconds,
                participants: minute.participants,
                participantNames: minute.participantNames,
                summary: minute.summary,
                keyDecisions: minute.keyDecisions,
                actionItems: minute.actionItems,
                rawTranscript: minute.rawTranscript,
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save minutes: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.auto_awesome, color: Colors.blue.shade700, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI Chat Summary',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      widget.conversationTitle,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const Divider(height: 24),

          // Content
          Flexible(
            child: SingleChildScrollView(
              child: _buildBody(),
            ),
          ),

          if (_summary != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _summary!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Summary copied to clipboard')),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: const Text('Save Minutes'),
                    onPressed: _saveAsMinutes,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Column(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                'Groq AI is summarizing the conversation...',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 6),
              Text(
                'Analyzing messages, topics, and key points',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(Icons.error_outline, size: 40, color: Colors.red.shade300),
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.red),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _generateSummary,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Text(
        _summary ?? '',
        style: const TextStyle(fontSize: 14.5, height: 1.5, color: Colors.black87),
      ),
    );
  }
}
