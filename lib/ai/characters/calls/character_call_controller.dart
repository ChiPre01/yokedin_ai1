import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:yoked_in/ai/characters/character_ai_service.dart';
import 'package:yoked_in/ai/characters/character_model.dart';
import 'package:yoked_in/ai/characters/characters_service.dart';
import 'package:yoked_in/ai/characters/chat/character_chat_service.dart';

enum CharacterCallStatus {
  connecting,
  listening,
  thinking,
  speaking,
  ended,
}

class CharacterCallState {
  const CharacterCallState({
    required this.status,
    this.currentTranscript = '',
    this.characterSubtitle = '',
    this.duration = Duration.zero,
    this.isMuted = false,
    this.isSpeakerOn = true,
    this.errorMessage,
    this.sttAvailable = true,
  });

  final CharacterCallStatus status;
  final String currentTranscript;
  final String characterSubtitle;
  final Duration duration;
  final bool isMuted;
  final bool isSpeakerOn;
  final String? errorMessage;
  final bool sttAvailable;

  bool get isConnecting => status == CharacterCallStatus.connecting;
  bool get isListening => status == CharacterCallStatus.listening;
  bool get isThinking => status == CharacterCallStatus.thinking;
  bool get isSpeaking => status == CharacterCallStatus.speaking;
  bool get isEnded => status == CharacterCallStatus.ended;

  CharacterCallState copyWith({
    CharacterCallStatus? status,
    String? currentTranscript,
    String? characterSubtitle,
    Duration? duration,
    bool? isMuted,
    bool? isSpeakerOn,
    String? errorMessage,
    bool? sttAvailable,
  }) {
    return CharacterCallState(
      status: status ?? this.status,
      currentTranscript: currentTranscript ?? this.currentTranscript,
      characterSubtitle: characterSubtitle ?? this.characterSubtitle,
      duration: duration ?? this.duration,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      errorMessage: errorMessage,
      sttAvailable: sttAvailable ?? this.sttAvailable,
    );
  }
}

/// Controller managing STT, TTS, LLM conversational turns, and call timer.
class CharacterCallController extends StateNotifier<CharacterCallState> {
  CharacterCallController({
    required this.characterId,
    required this.character,
    required this.ref,
    required this.isVideoCall,
  }) : super(const CharacterCallState(status: CharacterCallStatus.connecting)) {
    _init();
  }

  final String characterId;
  final AiCharacter? character;
  final Ref ref;
  final bool isVideoCall;

  final FlutterTts _flutterTts = FlutterTts();
  final stt.SpeechToText _speechToText = stt.SpeechToText();

  Timer? _callTimer;
  Timer? _connectTimer;
  Timer? _silenceTimer;
  String? _conversationId;
  bool _isDisposed = false;

  Future<void> _init() async {
    try {
      // 1. Ensure Firestore conversation exists
      final chatService = ref.read(characterChatServiceProvider);
      _conversationId = await chatService.ensureConversation(
        characterId: characterId,
        characterName: character?.name ?? 'Character',
        characterImageKey: character?.imageKey ?? '',
      );

      // 2. Setup TTS
      await _setupTts();

      // 3. Setup STT & Microphone permission
      await _setupStt();

      // 4. Simulate realistic call pickup after 1.5 seconds
      _connectTimer = Timer(const Duration(milliseconds: 1500), () {
        if (_isDisposed) return;
        _startCallTimer();
        _greetUser();
      });
    } catch (e) {
      debugPrint('Character call init error: $e');
      if (!_isDisposed) {
        state = state.copyWith(
          status: CharacterCallStatus.listening,
          errorMessage: 'Could not connect. You can tap to talk.',
        );
      }
    }
  }

  Future<void> _setupTts() async {
    try {
      await _flutterTts.setLanguage('en-US');
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);

      // Modulate pitch slightly based on role
      double pitch = 1.0;
      final role = character?.role.toLowerCase() ?? '';
      if (role == 'companion' || role == 'storyteller') {
        pitch = 1.08;
      } else if (role == 'tutor') {
        pitch = 0.98;
      }
      await _flutterTts.setPitch(pitch);

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await _flutterTts.setSharedInstance(true);
        await _flutterTts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playAndRecord,
          [
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
          ],
        );
      }

      _flutterTts.setStartHandler(() {
        if (!_isDisposed && state.status != CharacterCallStatus.ended) {
          state = state.copyWith(status: CharacterCallStatus.speaking);
        }
      });

      _flutterTts.setCompletionHandler(() {
        if (!_isDisposed && state.status != CharacterCallStatus.ended) {
          // Finished speaking -> listen for user's response
          _startListening();
        }
      });

      _flutterTts.setErrorHandler((dynamic msg) {
        debugPrint('TTS Error: $msg');
        if (!_isDisposed && state.status != CharacterCallStatus.ended) {
          _startListening();
        }
      });
    } catch (e) {
      debugPrint('TTS setup error: $e');
    }
  }

  Future<void> _setupStt() async {
    try {
      final micStatus = await Permission.microphone.request();
      if (micStatus.isGranted) {
        final available = await _speechToText.initialize(
          onError: (error) {
            debugPrint('STT error: ${error.errorMsg}');
          },
          onStatus: (status) {
            debugPrint('STT status: $status');
          },
        );
        state = state.copyWith(sttAvailable: available);
      } else {
        state = state.copyWith(
          sttAvailable: false,
          errorMessage: 'Microphone permission needed to speak.',
        );
      }
    } catch (e) {
      debugPrint('STT setup error: $e');
      state = state.copyWith(sttAvailable: false);
    }
  }

  void _startCallTimer() {
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isDisposed) return;
      state = state.copyWith(duration: state.duration + const Duration(seconds: 1));
    });
  }

  /// Initial greeting spoken by the character when the call answers
  Future<void> _greetUser() async {
    final role = character?.role.toLowerCase() ?? '';

    String greeting = "Hey! Great to hear from you. What's on your mind?";
    if (role == 'tutor') {
      greeting = "Hello! Ready for our session today? What would you like to explore?";
    } else if (role == 'musician') {
      greeting = "Hey! What kind of tunes or ideas are we jamming on today?";
    } else if (role == 'storyteller') {
      greeting = "Greetings! What world or adventure shall we journey into today?";
    }

    await _speak(greeting);
  }

  /// Start listening to user speech via STT
  Future<void> _startListening() async {
    if (_isDisposed || state.isMuted || state.status == CharacterCallStatus.ended) {
      return;
    }

    state = state.copyWith(
      status: CharacterCallStatus.listening,
      currentTranscript: '',
    );

    if (!state.sttAvailable) return;

    try {
      if (_speechToText.isListening) {
        await _speechToText.stop();
      }

      await _speechToText.listen(
        onResult: (result) {
          if (_isDisposed || state.status == CharacterCallStatus.ended) return;

          final words = result.recognizedWords;
          state = state.copyWith(currentTranscript: words);

          // Reset silence timer on receiving new speech
          _silenceTimer?.cancel();

          if (result.finalResult) {
            if (words.trim().isNotEmpty) {
              _onUserFinishedSpeaking(words.trim());
            }
          } else {
            // If user pauses for 1.8 seconds after speaking some words
            if (words.trim().isNotEmpty) {
              _silenceTimer = Timer(const Duration(milliseconds: 1800), () {
                if (_speechToText.isListening) {
                  _speechToText.stop();
                }
                _onUserFinishedSpeaking(words.trim());
              });
            }
          }
        },
        listenOptions: stt.SpeechListenOptions(
          listenMode: stt.ListenMode.dictation,
          partialResults: true,
          cancelOnError: false,
        ),
      );
    } catch (e) {
      debugPrint('STT listen error: $e');
    }
  }

  /// Called when user finishes speaking their turn
  Future<void> _onUserFinishedSpeaking(String text) async {
    if (_isDisposed || state.status == CharacterCallStatus.ended) return;
    _silenceTimer?.cancel();

    if (_speechToText.isListening) {
      await _speechToText.stop();
    }

    state = state.copyWith(
      status: CharacterCallStatus.thinking,
      currentTranscript: text,
    );

    final convId = _conversationId;
    if (convId == null) return;

    try {
      final chatService = ref.read(characterChatServiceProvider);

      // 1. Save user speech to Firestore
      await chatService.addUserMessage(
        conversationId: convId,
        text: text,
      );

      // 2. Read recent turns for context
      final recent = await chatService.recentMessages(convId, limit: 10);

      // 3. Request reply from AI
      final aiService = ref.read(characterAiServiceProvider);
      final rawReply = await aiService.sendCharacterMessage(
        characterId: characterId,
        recentMessages: recent,
      );

      if (_isDisposed || state.status == CharacterCallStatus.ended) return;

      // 4. Save character reply to Firestore
      await chatService.addCharacterMessage(
        conversationId: convId,
        text: rawReply,
      );

      // 5. Clean text for natural speech (remove *actions* and markdown)
      final speechText = _cleanTextForSpeech(rawReply);

      // 6. Speak the response
      await _speak(speechText, displaySubtitle: rawReply);
    } catch (e) {
      debugPrint('AI call turn error: $e');
      if (!_isDisposed && state.status != CharacterCallStatus.ended) {
        state = state.copyWith(
          status: CharacterCallStatus.listening,
          errorMessage: 'Sorry, I missed that. Could you say that again?',
        );
        _startListening();
      }
    }
  }

  /// Manually submit user speech (for tap-to-talk or on-screen input)
  Future<void> submitManualSpeech(String text) async {
    if (text.trim().isEmpty) return;
    await _onUserFinishedSpeaking(text.trim());
  }

  /// Speak a phrase with TTS
  Future<void> _speak(String text, {String? displaySubtitle}) async {
    if (_isDisposed || state.status == CharacterCallStatus.ended) return;

    state = state.copyWith(
      status: CharacterCallStatus.speaking,
      characterSubtitle: displaySubtitle ?? text,
    );

    try {
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint('TTS speak error: $e');
      _startListening();
    }
  }

  /// User taps "Interrupt" or starts speaking while character is talking
  Future<void> interrupt() async {
    try {
      await _flutterTts.stop();
    } catch (_) {}
    _startListening();
  }

  /// Toggle mute
  void toggleMute() {
    final nextMute = !state.isMuted;
    state = state.copyWith(isMuted: nextMute);
    if (nextMute) {
      _speechToText.stop();
    } else {
      if (state.status == CharacterCallStatus.listening) {
        _startListening();
      }
    }
  }

  /// Toggle speakerphone
  void toggleSpeaker() {
    state = state.copyWith(isSpeakerOn: !state.isSpeakerOn);
  }

  /// End the call
  Future<void> endCall() async {
    if (_isDisposed) return;
    _isDisposed = true;

    _callTimer?.cancel();
    _connectTimer?.cancel();
    _silenceTimer?.cancel();

    try {
      await _flutterTts.stop();
    } catch (_) {}

    try {
      await _speechToText.stop();
    } catch (_) {}

    state = state.copyWith(status: CharacterCallStatus.ended);
  }

  /// Strips roleplay asterisks like *smiles* and markdown characters
  String _cleanTextForSpeech(String input) {
    // Remove text inside asterisks (e.g. *giggles*, *looks thoughtfully*)
    String cleaned = input.replaceAll(RegExp(r'\*[^*]*\*'), '');
    // Remove markdown headers, bullets, or emojis that TTS would awkwardly read
    cleaned = cleaned.replaceAll(RegExp(r'[#*_`~]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned.isNotEmpty ? cleaned : input;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _callTimer?.cancel();
    _connectTimer?.cancel();
    _silenceTimer?.cancel();
    _flutterTts.stop();
    _speechToText.stop();
    super.dispose();
  }
}

final characterCallControllerProvider = StateNotifierProvider.autoDispose
    .family<CharacterCallController, CharacterCallState, (String, bool)>(
  (ref, params) {
    final (characterId, isVideoCall) = params;
    final character = ref.watch(characterStreamProvider(characterId)).asData?.value;
    return CharacterCallController(
      characterId: characterId,
      character: character,
      ref: ref,
      isVideoCall: isVideoCall,
    );
  },
);
