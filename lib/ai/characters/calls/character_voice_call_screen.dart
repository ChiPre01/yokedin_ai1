import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/ai/characters/calls/character_call_controller.dart';
import 'package:yoked_in/ai/characters/calls/character_call_widgets.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';

/// Full-screen AI Character Voice Call screen.
class CharacterVoiceCallScreen extends ConsumerStatefulWidget {
  const CharacterVoiceCallScreen({
    super.key,
    required this.characterId,
  });

  final String characterId;

  @override
  ConsumerState<CharacterVoiceCallScreen> createState() =>
      _CharacterVoiceCallScreenState();
}

class _CharacterVoiceCallScreenState
    extends ConsumerState<CharacterVoiceCallScreen> {
  final TextEditingController _manualTextController = TextEditingController();

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  void _showManualInputDialog(CharacterCallController controller) {
    _manualTextController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey.shade900,
        title: const Text(
          'Type to your character',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: TextField(
          controller: _manualTextController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Say something…',
            hintStyle: TextStyle(color: Colors.grey.shade500),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.deepPurple.shade300),
            ),
          ),
          onSubmitted: (val) {
            Navigator.pop(ctx);
            if (val.trim().isNotEmpty) {
              controller.submitManualSpeech(val.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.deepPurple),
            onPressed: () {
              Navigator.pop(ctx);
              if (_manualTextController.text.trim().isNotEmpty) {
                controller.submitManualSpeech(_manualTextController.text.trim());
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _manualTextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final characterAsync =
        ref.watch(characterStreamProvider(widget.characterId));
    final character = characterAsync.asData?.value;
    final characterName = character?.name.isNotEmpty == true
        ? character!.name
        : 'AI Character';

    final callState = ref.watch(
      characterCallControllerProvider((widget.characterId, false)),
    );
    final callController = ref.read(
      characterCallControllerProvider((widget.characterId, false)).notifier,
    );

    // If call ended, automatically pop screen
    ref.listen<CharacterCallState>(
      characterCallControllerProvider((widget.characterId, false)),
      (previous, next) {
        if (next.status == CharacterCallStatus.ended && mounted) {
          Navigator.of(context).pop();
        }
      },
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          callController.endCall();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F0E17),
        body: SafeArea(
          child: Column(
            children: [
              // 1. Top bar: Back, Name, Role, Timer, Status Chip
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white70),
                      onPressed: () => callController.endCall(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            characterName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              _StatusDot(status: callState.status),
                              const SizedBox(width: 6),
                              Text(
                                _statusLabel(callState.status),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 12.5,
                                ),
                              ),
                              if (callState.status !=
                                  CharacterCallStatus.connecting) ...[
                                const SizedBox(width: 8),
                                Text(
                                  '·  ${_formatDuration(callState.duration)}',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Type message',
                      icon: const Icon(Icons.keyboard_outlined, color: Colors.white70),
                      onPressed: () => _showManualInputDialog(callController),
                    ),
                  ],
                ),
              ),

              // 2. Center: Concentric pulse rings & Avatar
              Expanded(
                child: Center(
                  child: ConcentricPulseRings(
                    status: callState.status,
                    size: 160,
                    child: CallAvatar(
                      character: character,
                      fallbackName: characterName,
                      size: 140,
                    ),
                  ),
                ),
              ),

              // 3. Captions banner: Live speech subtitles
              CallCaptionsBanner(
                status: callState.status,
                userTranscript: callState.currentTranscript,
                characterSubtitle: callState.characterSubtitle,
                characterName: characterName,
              ),

              // 4. Error or Helper hint
              if (callState.errorMessage != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                  child: Text(
                    callState.errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.amberAccent, fontSize: 12),
                  ),
                )
              else if (callState.status == CharacterCallStatus.listening)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
                  child: Text(
                    callState.isMuted
                        ? 'Microphone is muted'
                        : 'Listening to you… Speak naturally',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12.5,
                    ),
                  ),
                ),

              const SizedBox(height: 16),

              // 5. Bottom Control Dock
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    // Mute button
                    _CircleActionButton(
                      icon: callState.isMuted
                          ? Icons.mic_off
                          : Icons.mic_none_outlined,
                      label: callState.isMuted ? 'Unmute' : 'Mute',
                      isActive: callState.isMuted,
                      onTap: () => callController.toggleMute(),
                    ),

                    // Interrupt / Speak button
                    if (callState.status == CharacterCallStatus.speaking)
                      _CircleActionButton(
                        icon: Icons.pause_circle_outline,
                        label: 'Interrupt',
                        isActive: true,
                        activeColor: Colors.deepPurpleAccent,
                        onTap: () => callController.interrupt(),
                      )
                    else
                      _CircleActionButton(
                        icon: callState.isSpeakerOn
                            ? Icons.volume_up
                            : Icons.volume_off,
                        label: callState.isSpeakerOn ? 'Speaker' : 'Earpiece',
                        isActive: callState.isSpeakerOn,
                        onTap: () => callController.toggleSpeaker(),
                      ),

                    // End Call
                    _CircleActionButton(
                      icon: Icons.call_end,
                      label: 'End',
                      backgroundColor: Colors.redAccent.shade400,
                      iconColor: Colors.white,
                      onTap: () => callController.endCall(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLabel(CharacterCallStatus status) {
    switch (status) {
      case CharacterCallStatus.connecting:
        return 'Calling…';
      case CharacterCallStatus.listening:
        return 'Listening…';
      case CharacterCallStatus.thinking:
        return 'Thinking…';
      case CharacterCallStatus.speaking:
        return 'Speaking…';
      case CharacterCallStatus.ended:
        return 'Call ended';
    }
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final CharacterCallStatus status;

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (status) {
      case CharacterCallStatus.connecting:
        color = Colors.orangeAccent;
        break;
      case CharacterCallStatus.listening:
        color = Colors.tealAccent;
        break;
      case CharacterCallStatus.thinking:
        color = Colors.amberAccent;
        break;
      case CharacterCallStatus.speaking:
        color = Colors.deepPurpleAccent.shade100;
        break;
      case CharacterCallStatus.ended:
        color = Colors.grey;
        break;
    }

    return Container(
      height: 8,
      width: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.6),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

class _CircleActionButton extends StatelessWidget {
  const _CircleActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
    this.backgroundColor,
    this.iconColor,
    this.activeColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final Color? backgroundColor;
  final Color? iconColor;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final bgColor = backgroundColor ??
        (isActive
            ? (activeColor ?? Colors.white.withValues(alpha: 0.25))
            : Colors.white.withValues(alpha: 0.12));
    final iColor = iconColor ?? Colors.white;

    return InkWell(
      borderRadius: BorderRadius.circular(32),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 54,
              width: 54,
              decoration: BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iColor, size: 26),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
