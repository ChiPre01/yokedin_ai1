import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/config/ai_config.dart';
import 'package:yoked_in/ai/screens/meeting_minutes_detail_screen.dart';
import 'package:yoked_in/ai/services/groq_service.dart';

void showGenerateMinutesAISheet({
  required BuildContext context,
  required WidgetRef ref,
  required String conversationId,
  required String conversationTitle,
  required String conversationType,
  String? otherUserId,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _GenerateMinutesAISheet(
      conversationId: conversationId,
      conversationTitle: conversationTitle,
      conversationType: conversationType,
      otherUserId: otherUserId,
    ),
  );
}

class _GenerateMinutesAISheet extends ConsumerStatefulWidget {
  final String conversationId;
  final String conversationTitle;
  final String conversationType;
  final String? otherUserId;

  const _GenerateMinutesAISheet({
    required this.conversationId,
    required this.conversationTitle,
    required this.conversationType,
    this.otherUserId,
  });

  @override
  ConsumerState<_GenerateMinutesAISheet> createState() =>
      _GenerateMinutesAISheetState();
}

class _GenerateMinutesAISheetState
    extends ConsumerState<_GenerateMinutesAISheet> {
  final TextEditingController _contentController = TextEditingController();
  bool _isGenerating = false;
  String? _errorMessage;

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  void _insertSampleDialogue() {
    _contentController.text = '''
Alice: Hey Bob! Thanks for joining the call today. How is the mobile app testing going?
Bob: Hey Alice! The testing is going well. The voice call quality is great with the noise suppression enabled. However, we noticed we need a cleaner way to review meeting minutes right from the chat.
Alice: Exactly. We decided to place the Minutes option inside the more menu on both 1-on-1 and group chats. Did you check that flow?
Bob: Yes, I tested it. Clicking Minutes displays all summarized titles with timestamps, and tapping any title opens the full executive summary and action items.
Alice: Perfect! Let's make sure we also add AI summarization so users don't have to write notes manually. Can you finalize the Firestore rules and verify the build on Android and iOS by Friday?
Bob: Absolutely, I will take care of the Firestore rules and mobile builds by Friday.
Alice: Great, and I will handle setting up the Groq Whisper backend endpoint for post-call audio transcription.
Bob: Sounds like a plan. Let's sync again next Monday at 10 AM to review everything.
Alice: Agreed! Talk to you Monday. Bye!
''';
    setState(() {});
  }

  Future<void> _generateMinutes() async {
    final content = _contentController.text.trim();
    if (content.isEmpty) {
      setState(() {
        _errorMessage =
            'Please enter conversation notes or tap "Use Sample Dialogue".';
      });
      return;
    }
    if (content.length > AIConfig.maxTranscriptCharacters) {
      setState(() {
        _errorMessage =
            'These notes are too long (${content.length} of '
            '${AIConfig.maxTranscriptCharacters} characters allowed). '
            'Please shorten them and try again.';
      });
      return;
    }

    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });

    try {
      final currentUserId =
          FirebaseAuth.instance.currentUser?.uid ?? 'current_user';
      final currentUserName =
          FirebaseAuth.instance.currentUser?.displayName ?? 'You';

      final participants = [currentUserId];
      final participantNames = <String, String>{currentUserId: currentUserName};

      if (widget.otherUserId != null) {
        participants.add(widget.otherUserId!);
        participantNames[widget.otherUserId!] = widget.conversationTitle;
      }

      final generatedMinute = await ref
          .read(groqServiceProvider)
          .generateAndSaveMeetingMinutes(
            conversationId: widget.conversationId,
            conversationType: widget.conversationType,
            conversationTitle: widget.conversationTitle,
            rawContent: content,
            participants: participants,
            participantNames: participantNames,
            durationSeconds: 300,
          );

      if (mounted) {
        Navigator.pop(context); // Close bottom sheet
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Meeting minutes generated and saved!'),
            behavior: SnackBarBehavior.floating,
          ),
        );

        // Open newly created minutes detail screen
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                MeetingMinutesDetailScreen(minute: generatedMinute),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e is AiServiceException
              ? e.message
              : e.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      // Always release the button spinner, no matter how the call ended.
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
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
                child: Icon(Icons.auto_awesome,
                    color: Colors.blue.shade700, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Generate Minutes with Groq AI',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'AI Conversation Intelligence (${AIConfig.groqModel})',
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
          const Divider(height: 20),

          // Body
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Call Transcript or Notes:',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.paste_rounded, size: 16),
                        label: const Text('Use Sample Dialogue',
                            style: TextStyle(fontSize: 12)),
                        onPressed: _insertSampleDialogue,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _contentController,
                    maxLines: 7,
                    decoration: InputDecoration(
                      hintText:
                          'Paste conversation transcript, dialogue, or call notes here...',
                      hintStyle:
                          TextStyle(fontSize: 13, color: Colors.grey.shade400),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                  ),

                  if (_errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              color: Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _isGenerating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.auto_awesome, size: 20),
              label: Text(
                _isGenerating
                    ? 'Groq AI is analyzing conversation...'
                    : 'Generate Meeting Minutes',
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              onPressed: _isGenerating ? null : _generateMinutes,
            ),
          ),
        ],
      ),
    );
  }
}
