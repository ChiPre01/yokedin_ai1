import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:yoked_in/ai/characters/calls/character_call_controller.dart';
import 'package:yoked_in/ai/characters/calls/character_call_widgets.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

/// Full-screen AI Character Video Call screen with camera PiP.
class CharacterVideoCallScreen extends ConsumerStatefulWidget {
  const CharacterVideoCallScreen({
    super.key,
    required this.characterId,
  });

  final String characterId;

  @override
  ConsumerState<CharacterVideoCallScreen> createState() =>
      _CharacterVideoCallScreenState();
}

class _CharacterVideoCallScreenState
    extends ConsumerState<CharacterVideoCallScreen>
    with SingleTickerProviderStateMixin {
  List<CameraDescription> _cameras = [];
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _isCameraEnabled = true;
  int _selectedCameraIndex = 0;

  late AnimationController _ambientAnimController;

  @override
  void initState() {
    super.initState();
    _ambientAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);

    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) return;

      _cameras = await availableCameras();
      if (_cameras.isEmpty) return;

      // Prefer front camera for video calls
      final frontIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      _selectedCameraIndex = frontIndex != -1 ? frontIndex : 0;

      await _setupCameraController(_cameras[_selectedCameraIndex]);
    } catch (e) {
      debugPrint('Video call camera init error: $e');
    }
  }

  Future<void> _setupCameraController(CameraDescription description) async {
    try {
      final prevController = _cameraController;
      final controller = CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      await prevController?.dispose();
      await controller.initialize();

      if (mounted) {
        setState(() {
          _cameraController = controller;
          _isCameraReady = true;
        });
      }
    } catch (e) {
      debugPrint('Setup camera controller error: $e');
      if (mounted) {
        setState(() {
          _isCameraReady = false;
        });
      }
    }
  }

  Future<void> _flipCamera() async {
    if (_cameras.length < 2) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _setupCameraController(_cameras[_selectedCameraIndex]);
  }

  void _toggleCamera() {
    setState(() {
      _isCameraEnabled = !_isCameraEnabled;
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _ambientAnimController.dispose();
    _cameraController?.dispose();
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
      characterCallControllerProvider((widget.characterId, true)),
    );
    final callController = ref.read(
      characterCallControllerProvider((widget.characterId, true)).notifier,
    );

    ref.listen<CharacterCallState>(
      characterCallControllerProvider((widget.characterId, true)),
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
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 1. Full-screen Character Backdrop with subtle breathing animation
            _CharacterBackdrop(
              character: character,
              characterName: characterName,
              animation: _ambientAnimController,
              isSpeaking: callState.status == CharacterCallStatus.speaking,
            ),

            // 2. Gradient overlays for legibility
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.75),
                      Colors.transparent,
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.85),
                    ],
                    stops: const [0.0, 0.22, 0.65, 1.0],
                  ),
                ),
              ),
            ),

            // 3. Floating User Camera PiP
            if (_isCameraEnabled)
              DraggableCameraPip(
                cameraController: _cameraController,
                isCameraReady: _isCameraReady,
                onFlipCamera: _flipCamera,
              ),

            // 4. Foreground UI: Top Bar, Captions, Controls
            SafeArea(
              child: Column(
                children: [
                  // Top Navigation Bar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
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
                                  _VideoCallStatusIndicator(
                                    status: callState.status,
                                  ),
                                  if (callState.status !=
                                      CharacterCallStatus.connecting) ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      _formatDuration(callState.duration),
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.6),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // Live Captions Banner
                  CallCaptionsBanner(
                    status: callState.status,
                    userTranscript: callState.currentTranscript,
                    characterSubtitle: callState.characterSubtitle,
                    characterName: characterName,
                  ),

                  // Helper text
                  if (callState.status == CharacterCallStatus.listening)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 4,
                      ),
                      child: Text(
                        callState.isMuted
                            ? 'Muted'
                            : 'Listening to you…',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 13,
                        ),
                      ),
                    ),

                  const SizedBox(height: 12),

                  // Bottom Control Dock
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        // Mute Mic
                        _VideoCallActionButton(
                          icon: callState.isMuted
                              ? Icons.mic_off
                              : Icons.mic_none_outlined,
                          label: callState.isMuted ? 'Unmute' : 'Mute',
                          isActive: callState.isMuted,
                          onTap: () => callController.toggleMute(),
                        ),

                        // Toggle Camera
                        _VideoCallActionButton(
                          icon: _isCameraEnabled
                              ? Icons.videocam_outlined
                              : Icons.videocam_off_outlined,
                          label: _isCameraEnabled ? 'Cam Off' : 'Cam On',
                          isActive: !_isCameraEnabled,
                          onTap: _toggleCamera,
                        ),

                        // Flip Camera
                        _VideoCallActionButton(
                          icon: Icons.flip_camera_ios_outlined,
                          label: 'Flip',
                          onTap: _flipCamera,
                        ),

                        // End Call
                        _VideoCallActionButton(
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
          ],
        ),
      ),
    );
  }
}

class _CharacterBackdrop extends StatelessWidget {
  const _CharacterBackdrop({
    required this.character,
    required this.characterName,
    required this.animation,
    required this.isSpeaking,
  });

  final AiCharacter? character;
  final String characterName;
  final Animation<double> animation;
  final bool isSpeaking;

  @override
  Widget build(BuildContext context) {
    final value = character;

    final fallback = Center(
      child: Container(
        height: 140,
        width: 140,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.deepPurple.shade900,
          shape: BoxShape.circle,
        ),
        child: Text(
          characterName.isNotEmpty ? characterName[0].toUpperCase() : 'AI',
          style: const TextStyle(
            fontSize: 48,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        // Subtle ambient scale effect
        final scale = 1.0 + (animation.value * 0.03);

        return Transform.scale(
          scale: scale,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (value != null && value.hasPortrait)
                CloudflareMediaImage(
                  imageUrl: value.imageUrl,
                  fit: BoxFit.cover,
                  cacheWidth: 1080,
                  error: fallback,
                )
              else
                fallback,

              // Speaking glow edge effect
              if (isSpeaking)
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Colors.deepPurpleAccent.withValues(alpha: 0.4),
                      width: 6,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _VideoCallStatusIndicator extends StatelessWidget {
  const _VideoCallStatusIndicator({required this.status});

  final CharacterCallStatus status;

  @override
  Widget build(BuildContext context) {
    Color dotColor = Colors.tealAccent;
    String text = 'Connected';

    switch (status) {
      case CharacterCallStatus.connecting:
        dotColor = Colors.orangeAccent;
        text = 'Connecting…';
        break;
      case CharacterCallStatus.listening:
        dotColor = Colors.tealAccent;
        text = 'Listening…';
        break;
      case CharacterCallStatus.thinking:
        dotColor = Colors.amberAccent;
        text = 'Thinking…';
        break;
      case CharacterCallStatus.speaking:
        dotColor = Colors.deepPurpleAccent.shade100;
        text = 'Speaking…';
        break;
      case CharacterCallStatus.ended:
        dotColor = Colors.grey;
        text = 'Ended';
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 7,
          width: 7,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _VideoCallActionButton extends StatelessWidget {
  const _VideoCallActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
    this.backgroundColor,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final Color? backgroundColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final bgColor = backgroundColor ??
        (isActive
            ? Colors.white.withValues(alpha: 0.3)
            : Colors.white.withValues(alpha: 0.12));
    final iColor = iconColor ?? Colors.white;

    return InkWell(
      borderRadius: BorderRadius.circular(28),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 48,
              width: 48,
              decoration: BoxDecoration(
                color: bgColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iColor, size: 22),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
