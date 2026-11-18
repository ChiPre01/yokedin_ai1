import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:yoked_in/ai/characters/calls/character_call_controller.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

/// Animated concentric rings that pulse around the avatar during speech or listening.
class ConcentricPulseRings extends StatefulWidget {
  const ConcentricPulseRings({
    super.key,
    required this.status,
    required this.child,
    this.size = 180,
  });

  final CharacterCallStatus status;
  final Widget child;
  final double size;

  @override
  State<ConcentricPulseRings> createState() => _ConcentricPulseRingsState();
}

class _ConcentricPulseRingsState extends State<ConcentricPulseRings>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant ConcentricPulseRings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status == CharacterCallStatus.speaking) {
      if (!_animController.isAnimating) _animController.repeat();
    } else if (widget.status == CharacterCallStatus.thinking) {
      _animController.duration = const Duration(milliseconds: 900);
      if (!_animController.isAnimating) _animController.repeat();
    } else if (widget.status == CharacterCallStatus.listening) {
      _animController.duration = const Duration(milliseconds: 2200);
      if (!_animController.isAnimating) _animController.repeat();
    } else {
      _animController.stop();
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color ringColor;
    if (widget.status == CharacterCallStatus.speaking) {
      ringColor = Colors.deepPurpleAccent;
    } else if (widget.status == CharacterCallStatus.listening) {
      ringColor = Colors.tealAccent;
    } else if (widget.status == CharacterCallStatus.thinking) {
      ringColor = Colors.amberAccent;
    } else {
      ringColor = Colors.white54;
    }

    return AnimatedBuilder(
      animation: _animController,
      builder: (context, child) {
        final val = _animController.value;
        return SizedBox(
          height: widget.size * 1.6,
          width: widget.size * 1.6,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer wave
              if (widget.status == CharacterCallStatus.speaking ||
                  widget.status == CharacterCallStatus.listening)
                Container(
                  height: widget.size + (val * 70),
                  width: widget.size + (val * 70),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ringColor.withValues(alpha: (1.0 - val) * 0.35),
                      width: 2.5,
                    ),
                  ),
                ),
              // Inner wave
              if (widget.status == CharacterCallStatus.speaking)
                Container(
                  height: widget.size + (val * 35),
                  width: widget.size + (val * 35),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: ringColor.withValues(alpha: (1.0 - val) * 0.6),
                      width: 3.5,
                    ),
                  ),
                ),
              widget.child,
            ],
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Character Avatar Circle with fallback initials and portrait support.
class CallAvatar extends StatelessWidget {
  const CallAvatar({
    super.key,
    required this.character,
    this.fallbackName = 'Character',
    this.size = 140,
  });

  final AiCharacter? character;
  final String fallbackName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final value = character;
    final initials = (value?.name ?? fallbackName).trim().isNotEmpty
        ? (value?.name ?? fallbackName).trim().substring(0, 1).toUpperCase()
        : 'AI';

    final fallback = CircleAvatar(
      radius: size / 2,
      backgroundColor: Colors.deepPurple.shade900,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withValues(alpha: 0.4),
            blurRadius: 28,
            spreadRadius: 4,
          ),
        ],
      ),
      child: ClipOval(
        child: value != null && value.hasPortrait
            ? CloudflareMediaImage(
                imageUrl: value.imageUrl,
                fit: BoxFit.cover,
                cacheWidth: (size * 3).round(),
                error: fallback,
              )
            : fallback,
      ),
    );
  }
}

/// Floating live caption banner showing what the character is saying or user is speaking.
class CallCaptionsBanner extends StatelessWidget {
  const CallCaptionsBanner({
    super.key,
    required this.status,
    required this.userTranscript,
    required this.characterSubtitle,
    required this.characterName,
  });

  final CharacterCallStatus status;
  final String userTranscript;
  final String characterSubtitle;
  final String characterName;

  @override
  Widget build(BuildContext context) {
    String speakerLabel = '';
    String captionText = '';
    Color accentColor = Colors.white70;

    if (status == CharacterCallStatus.speaking && characterSubtitle.isNotEmpty) {
      speakerLabel = characterName;
      captionText = characterSubtitle;
      accentColor = Colors.deepPurpleAccent.shade100;
    } else if (status == CharacterCallStatus.listening && userTranscript.isNotEmpty) {
      speakerLabel = 'You';
      captionText = userTranscript;
      accentColor = Colors.tealAccent;
    } else if (status == CharacterCallStatus.thinking) {
      speakerLabel = characterName;
      captionText = 'Thinking…';
      accentColor = Colors.amberAccent;
    } else if (status == CharacterCallStatus.connecting) {
      speakerLabel = 'Status';
      captionText = 'Calling $characterName…';
    }

    if (captionText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                height: 8,
                width: 8,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                speakerLabel,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            captionText,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

/// Floating Draggable Picture-in-Picture window showing the user's front camera.
class DraggableCameraPip extends StatefulWidget {
  const DraggableCameraPip({
    super.key,
    required this.cameraController,
    required this.isCameraReady,
    required this.onFlipCamera,
  });

  final CameraController? cameraController;
  final bool isCameraReady;
  final VoidCallback onFlipCamera;

  @override
  State<DraggableCameraPip> createState() => _DraggableCameraPipState();
}

class _DraggableCameraPipState extends State<DraggableCameraPip> {
  Offset _position = const Offset(20, 80);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    const double pipWidth = 110;
    const double pipHeight = 155;

    return Positioned(
      left: _position.dx.clamp(16.0, size.width - pipWidth - 16.0),
      top: _position.dy.clamp(60.0, size.height - pipHeight - 120.0),
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _position += details.delta;
          });
        },
        child: Container(
          width: pipWidth,
          height: pipHeight,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.3), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(15),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.isCameraReady && widget.cameraController != null)
                  CameraPreview(widget.cameraController!)
                else
                  Container(
                    color: Colors.grey.shade900,
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.videocam_off_outlined,
                      color: Colors.white54,
                      size: 28,
                    ),
                  ),
                Positioned(
                  top: 6,
                  right: 6,
                  child: InkWell(
                    onTap: widget.onFlipCamera,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.flip_camera_ios,
                        color: Colors.white,
                        size: 14,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
