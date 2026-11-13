import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:yoked_in/auth/notification_service.dart';
import 'package:yoked_in/auth/user_login_screen.dart';
import 'package:yoked_in/auth/zego_secret_key.dart';
import 'package:yoked_in/calls/call_listener_menu_button.dart';
import 'package:yoked_in/calls/call_listener_service.dart';
import 'package:yoked_in/calls/call_meeting_coordinator.dart';
import 'package:yoked_in/calls/call_minimize_menu_button.dart';
import 'package:yoked_in/calls/call_recording_models.dart';
import 'package:yoked_in/calls/call_recording_retention.dart';
import 'package:yoked_in/firebase_options.dart';
import 'package:yoked_in/provider/provider.dart' as auth;
import 'package:yoked_in/wrapper_state/authentication_wrapper.dart';
import 'package:zego_uikit_prebuilt_call/zego_uikit_prebuilt_call.dart';
import 'package:zego_uikit_signaling_plugin/zego_uikit_signaling_plugin.dart';

final navigatorKey = GlobalKey<NavigatorState>();
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // ADD THIS: Initialize notification service FIRST
  await NotificationService().initialize();
  NotificationService().initTokenListener();

  ZegoUIKitPrebuiltCallInvitationService().setNavigatorKey(navigatorKey);

  // Recording alerts belong above the call page, so they are shown on the
  // root navigator.
  CallMeetingCoordinator.instance.navigatorKey = navigatorKey;
  // Call audio that outlived its 24-hour window is removed in the background.
  unawaited(CallRecordingRetention().sweepExpiredAudio());

  runApp(ProviderScope(child: MyApp(navigatorKey: navigatorKey)));

  // Permission prompts are OS dialogs. Asking before runApp meant every cold
  // start waited on them before the first frame; they now run once the app is
  // already visible.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(requestPermissions());
    unawaited(NotificationService().requestPermissions());
  });
}

/// Requests camera, microphone and notification permissions after the first
/// frame, so the app is usable while the OS dialogs are open.
Future<void> requestPermissions() async {
  await [
    Permission.camera,
    Permission.microphone,
    Permission.notification, // Needed for Android 13+
  ].request();
  // ADD THIS: Also request Firebase Messaging permission
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
  );
}

class MyApp extends ConsumerStatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  const MyApp({super.key, required this.navigatorKey});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  StreamSubscription<User?>? _zegoAuthSubscription;
  Future<void> _zegoSessionQueue = Future<void>.value();
  String? _zegoUserId;

  @override
  void initState() {
    super.initState();
    // Add observer to detect app lifecycle changes
    WidgetsBinding.instance.addObserver(this);
    _zegoAuthSubscription =
        FirebaseAuth.instance.authStateChanges().listen((user) {
      _zegoSessionQueue = _zegoSessionQueue.then(
        (_) => _syncZegoSession(user),
      );
    });
    // Validate user on app start
    _validateUserOnStart();
  }

  Future<void> _syncZegoSession(User? user) async {
    final callService = ZegoUIKitPrebuiltCallInvitationService();
    if (user?.uid == _zegoUserId) return;

    try {
      if (_zegoUserId != null) {
        await callService.uninit();
        _zegoUserId = null;
      }

      if (user == null) return;

      await callService.init(
        appID: ZegoConfig.appID,
        appSign: ZegoConfig.appSign,
        userID: user.uid,
        userName: user.displayName ?? 'User',
        plugins: [ZegoUIKitSignalingPlugin()],
        invitationEvents: ZegoUIKitPrebuiltCallInvitationEvents(),
        // Adds the AI listener button to the in-call menu bar.
        requireConfig: (data) {
          final isVideo = data.type == ZegoCallInvitationType.videoCall;
          final isGroup = data.invitees.length > 1;
          final config = isGroup
              ? (isVideo
                  ? ZegoUIKitPrebuiltCallConfig.groupVideoCall()
                  : ZegoUIKitPrebuiltCallConfig.groupVoiceCall())
              : (isVideo
                  ? ZegoUIKitPrebuiltCallConfig.oneOnOneVideoCall()
                  : ZegoUIKitPrebuiltCallConfig.oneOnOneVoiceCall());
          // The caller puts the conversation in customData, so both devices
          // can link their own recording to the same chat or group.
          final conversation =
              CallConversationInfo.tryParse(data.customData);
          config.bottomMenuBar.extendButtons = [
            CallListenerMenuButton(
              callId: data.callID,
              conversation: conversation,
            ),
          ];

          // ZEGO's own pop targets the navigator passed to it. The prebuilt
          // page lives on the root navigator, so point every internal pop
          // there; otherwise a group video call can stay on screen after
          // "minimize" because the wrong navigator was popped.
          config.rootNavigator = true;

          // A group video call fills the bottom bar, which pushes the built-in
          // minimize button into the overflow sheet. Keep an always-visible
          // "leave the call screen" control in the top bar.
          if (isGroup) {
            config.topMenuBar.isVisible = true;
            config.topMenuBar.extendButtons = [
              ...config.topMenuBar.extendButtons,
              CallMinimizeMenuButton(navigatorKey: navigatorKey),
            ];
          }

          // Watch this call's shared meeting so every participant sees the
          // "recording started" and "recording stopped" alerts.
          final currentUser = FirebaseAuth.instance.currentUser;
          if (currentUser != null) {
            unawaited(
              CallMeetingCoordinator.instance.attach(
                callId: data.callID,
                conversation: conversation,
                uid: currentUser.uid,
                name: currentUser.displayName ?? 'You',
              ),
            );
          }
          // A visible "leave the call screen" control. Tapping it minimizes the
          // call into a floating card instead of ending it, so the user can keep
          // using the app and tap the card to return to the call page.
          if (!config.bottomMenuBar.buttons
              .contains(ZegoCallMenuBarButtonName.minimizingButton)) {
            config.bottomMenuBar.buttons = [
              ...config.bottomMenuBar.buttons,
              ZegoCallMenuBarButtonName.minimizingButton,
            ];
          }
          // Re-apply here: the engine exists before any call publishes, so the
          // noise filter also covers calls that never pass through the button.
          CallListenerService.instance.primeNoiseSuppression();
          return config;
        },
        events: ZegoUIKitPrebuiltCallEvents(
          onCallEnd: (event, defaultAction) {
            // Finalise this device's audio and tell the other participants that
            // recording stopped, before the call page is torn down.
            unawaited(
              CallMeetingCoordinator.instance.detach(reason: 'left'),
            );
            defaultAction();
          },
        ),
      );
      _zegoUserId = user.uid;
    } catch (error, stackTrace) {
      debugPrint('Zego session update error: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  void dispose() {
    _zegoAuthSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Validate user when app resumes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _validateUserOnStart();
    }
  }

  // Validate user exists in Firestore
  Future<void> _validateUserOnStart() async {
    final authValidation = ref.read(auth.authValidationServiceProvider);
    final isValid = await authValidation.validateCurrentUser();

    if (!isValid) {
      // Refresh auth state to trigger navigation to login
      ref.invalidate(auth.authStateProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(auth.authStateProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      // Keeps a minimized call alive: the prebuilt call page is popped, so this
      // overlay is what shows the floating call card and restores the call page
      // when it is tapped. Without it, minimizing leaves nothing to return to.
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            ZegoUIKitPrebuiltCallMiniOverlayPage(
              contextQuery: () =>
                  navigatorKey.currentState?.context ?? context,
            ),
          ],
        );
      },
      home: authState.when(
        data: (user) {
          if (user != null) {
            return const AuthenticatedWrapper();
          } else {
            return const UserLoginScreen();
          }
        },
        loading: () =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (error, _) => Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: $error'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(auth.authStateProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
