import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:yoked_in/ai/models/meeting_minutes_model.dart';
import 'package:yoked_in/ai/services/meeting_minutes_service.dart';

class MeetingMinutesDetailScreen extends ConsumerStatefulWidget {
  final MeetingMinutesModel minute;

  const MeetingMinutesDetailScreen({super.key, required this.minute});

  @override
  ConsumerState<MeetingMinutesDetailScreen> createState() =>
      _MeetingMinutesDetailScreenState();
}

class _MeetingMinutesDetailScreenState
    extends ConsumerState<MeetingMinutesDetailScreen> {
  late MeetingMinutesModel _currentMinute;

  @override
  void initState() {
    super.initState();
    _currentMinute = widget.minute;
  }

  void _copyToClipboard() {
    final buffer = StringBuffer();
    buffer.writeln('📋 ${_currentMinute.title}');
    buffer.writeln('📅 Date: ${DateFormat('MMMM d, y • h:mm a').format(_currentMinute.createdAt)}');
    if (_currentMinute.formattedDuration.isNotEmpty) {
      buffer.writeln('⏱️ Duration: ${_currentMinute.formattedDuration}');
    }
    buffer.writeln();
    buffer.writeln('📝 SUMMARY:');
    buffer.writeln(_currentMinute.summary);
    buffer.writeln();

    if (_currentMinute.keyDecisions.isNotEmpty) {
      buffer.writeln('💡 KEY DECISIONS:');
      for (final decision in _currentMinute.keyDecisions) {
        buffer.writeln('• $decision');
      }
      buffer.writeln();
    }

    if (_currentMinute.actionItems.isNotEmpty) {
      buffer.writeln('✅ ACTION ITEMS:');
      for (final item in _currentMinute.actionItems) {
        final status = item.isCompleted ? '[X]' : '[ ]';
        final assignee = item.assignee != null ? ' (@${item.assignee})' : '';
        final due = item.dueDate != null ? ' [Due: ${item.dueDate}]' : '';
        buffer.writeln('$status ${item.task}$assignee$due');
      }
      buffer.writeln();
    }

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Meeting minutes copied to clipboard'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _toggleAction(int index, bool newValue) async {
    setState(() {
      final updatedList = List<ActionItemModel>.from(_currentMinute.actionItems);
      updatedList[index] = updatedList[index].copyWith(isCompleted: newValue);
      _currentMinute = MeetingMinutesModel(
        id: _currentMinute.id,
        conversationId: _currentMinute.conversationId,
        conversationType: _currentMinute.conversationType,
        title: _currentMinute.title,
        createdAt: _currentMinute.createdAt,
        durationSeconds: _currentMinute.durationSeconds,
        participants: _currentMinute.participants,
        participantNames: _currentMinute.participantNames,
        summary: _currentMinute.summary,
        keyDecisions: _currentMinute.keyDecisions,
        actionItems: updatedList,
        rawTranscript: _currentMinute.rawTranscript,
        meetingId: _currentMinute.meetingId,
        hiddenFor: _currentMinute.hiddenFor,
      );
    });

    try {
      await ref.read(meetingMinutesServiceProvider).toggleActionItem(
            _currentMinute.id,
            index,
            newValue,
          );
    } catch (e) {
      debugPrint('Failed to update action item: $e');
    }
  }

  Future<void> _deleteMinute() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Minutes'),
        content: const Text(
          'Remove these minutes from your account? Other participants keep '
          'their own copy, so nothing is deleted for them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await ref
          .read(meetingMinutesServiceProvider)
          .deleteMeetingMinute(_currentMinute.id);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Minutes removed from your account')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('EEEE, MMMM d, y • h:mm a');
    final formattedDate = dateFormat.format(_currentMinute.createdAt);

    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text(
          'Meeting Minutes',
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
        ),
        backgroundColor: Colors.white,
        elevation: 0.5,
        iconTheme: const IconThemeData(color: Colors.black87),
        actions: [
          IconButton(
            tooltip: 'Copy minutes',
            icon: const Icon(Icons.copy_rounded),
            onPressed: _copyToClipboard,
          ),
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'delete') _deleteMinute();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, color: Colors.red, size: 20),
                    SizedBox(width: 8),
                    Text('Delete Minutes', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header card
            _buildHeaderCard(formattedDate),
            const SizedBox(height: 16),

            // Summary section
            _buildSummaryCard(),
            const SizedBox(height: 16),

            // Key Decisions section
            if (_currentMinute.keyDecisions.isNotEmpty) ...[
              _buildDecisionsCard(),
              const SizedBox(height: 16),
            ],

            // Action Items section
            if (_currentMinute.actionItems.isNotEmpty) ...[
              _buildActionItemsCard(),
              const SizedBox(height: 16),
            ],

            // Transcript section
            if (_currentMinute.rawTranscript.isNotEmpty) ...[
              _buildTranscriptCard(),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard(String formattedDate) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.auto_awesome, color: Colors.blue.shade700, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _currentMinute.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.calendar_today_outlined, size: 16, color: Colors.grey.shade600),
              const SizedBox(width: 6),
              Text(
                formattedDate,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
              ),
            ],
          ),
          if (_currentMinute.formattedDuration.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.timer_outlined, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Text(
                  'Call duration: ${_currentMinute.formattedDuration}',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                ),
              ],
            ),
          ],
          if (_currentMinute.participantNames.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: _currentMinute.participantNames.values.map((name) {
                return Chip(
                  avatar: CircleAvatar(
                    backgroundColor: Colors.blue.shade100,
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade800,
                      ),
                    ),
                  ),
                  label: Text(name, style: const TextStyle(fontSize: 13)),
                  backgroundColor: Colors.grey.shade100,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.notes_rounded, color: Colors.blue.shade600, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Executive Summary',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _currentMinute.summary,
            style: const TextStyle(
              fontSize: 14.5,
              height: 1.5,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDecisionsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline_rounded,
                  color: Colors.amber.shade700, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Key Decisions',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ..._currentMinute.keyDecisions.map(
            (decision) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade100,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.check, size: 12, color: Colors.amber.shade900),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      decision,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionItemsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: Colors.green.shade600, size: 20),
              const SizedBox(width: 8),
              const Text(
                'Action Items',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._currentMinute.actionItems.asMap().entries.map((entry) {
            final index = entry.key;
            final item = entry.value;

            return Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: item.isCompleted ? Colors.grey.shade50 : Colors.green.shade50.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: item.isCompleted ? Colors.grey.shade300 : Colors.green.shade200,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: item.isCompleted,
                    activeColor: Colors.green.shade700,
                    onChanged: (val) {
                      if (val != null) _toggleAction(index, val);
                    },
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.task,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              decoration: item.isCompleted
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: item.isCompleted
                                  ? Colors.grey.shade600
                                  : Colors.black87,
                            ),
                          ),
                          if (item.assignee != null || item.dueDate != null) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              children: [
                                if (item.assignee != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade50,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '👤 ${item.assignee}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.blue.shade800,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                if (item.dueDate != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.shade50,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '📅 ${item.dueDate}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.orange.shade800,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTranscriptCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(Icons.record_voice_over_outlined, color: Colors.indigo.shade600),
          title: Text(
            'Call Transcript (${_currentMinute.rawTranscript.length} entries)',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: _currentMinute.rawTranscript.map((segment) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      segment.timestamp,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade800),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          segment.speaker,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          segment.text,
                          style: const TextStyle(fontSize: 13.5, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
