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
  await NotificationService().requestPermissions();
  NotificationService().initTokenListener();

  // Request camera, microphone, and notification permissions for call support.
  await requestPermissions();
  ZegoUIKitPrebuiltCallInvitationService().setNavigatorKey(navigatorKey);

  runApp(ProviderScope(child: MyApp(navigatorKey: navigatorKey)));
}

// 🔔 Request camera, mic, and notification permissions
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
