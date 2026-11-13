import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yoked_in/auth/display_name_service.dart';
import 'package:yoked_in/auth/notification_service.dart';

class AuthMethod {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final DisplayNameService _displayNameService = DisplayNameService();

  Future<String> signUpUser({
    required String email,
    required String password,
    required String name,
  }) async {
    User? createdUser;

    try {
      final trimmedName = name.trim();
      final trimmedEmail = email.trim();

      if (trimmedEmail.isEmpty || password.isEmpty || trimmedName.isEmpty) {
        return 'Please enter all fields';
      }

      // Create the Firebase Authentication account first.
      // Firestore rules can now recognize this authenticated user.
      final credential = await _auth.createUserWithEmailAndPassword(
        email: trimmedEmail,
        password: password,
      );

      createdUser = credential.user;

      if (createdUser == null) {
        return 'Account creation failed. Please try again.';
      }

      await createdUser.updateDisplayName(trimmedName);

      // Check for duplicate names. This scans the users collection, so it is
      // bounded: if it cannot finish (offline, rules, large collection) the
      // account is still created instead of hanging or being rolled back.
      final nameTaken = await _isNameTaken(
        trimmedName,
        excludeUid: createdUser.uid,
      );

      if (nameTaken) {
        // Remove the newly created account because the name is unavailable.
        await createdUser.delete();
        createdUser = null;

        return 'This name is already taken. Please choose a different name.';
      }

      // Create the profile in the existing users collection. This must happen
      // before anything slow (FCM token): it is the step that used to be
      // skipped when the app was killed while sign-up was still waiting.
      await _firestore.collection('users').doc(createdUser.uid).set({
        'uid': createdUser.uid,
        ..._displayNameService.nameFields(trimmedName),
        'email': trimmedEmail,
        'photoURL': null,
        'isOnline': true,
        'provider': 'email',
        'lastSeen': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'token': null,
      }).timeout(const Duration(seconds: 15));

      // The notification token is best-effort and must never delay sign-up.
      unawaited(_syncNotificationToken(createdUser.uid));

      return 'success';
    } on FirebaseAuthException catch (e) {
      return e.message ?? 'Unable to create your account.';
    } on FirebaseException catch (e) {
      debugPrint('[SIGNUP] Firebase error: ${e.code} - ${e.message}');

      // If profile creation fails, avoid leaving an orphaned Auth account.
      if (createdUser != null) {
        try {
          await createdUser.delete();
        } catch (cleanupError) {
          debugPrint('[SIGNUP] Account cleanup failed: $cleanupError');
        }
      }

      return 'Unable to create your account: ${e.message ?? e.code}';
    } catch (e) {
      debugPrint('[SIGNUP] Unexpected error: $e');
      return 'Unable to create your account: $e';
    }
  }

  /// Returns false instead of throwing when the check cannot be completed.
  Future<bool> _isNameTaken(String name, {String? excludeUid}) async {
    try {
      return await _displayNameService
          .isNameTaken(name, excludeUid: excludeUid)
          .timeout(const Duration(seconds: 6));
    } catch (e) {
      debugPrint('[SIGNUP] Name uniqueness check skipped: $e');
      return false;
    }
  }

  /// Stores the FCM token in the background so it never blocks authentication.
  Future<void> _syncNotificationToken(String uid) async {
    try {
      final token = await NotificationService()
          .getToken()
          .timeout(const Duration(seconds: 10));

      if (token == null) {
        debugPrint('[AUTH] No FCM token available for $uid yet.');
        return;
      }

      await _firestore.collection('users').doc(uid).update({
        'token': token,
        'lastSeen': FieldValue.serverTimestamp(),
        'isOnline': true,
      }).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[AUTH] Notification token update skipped: $e');
    }
  }

  // Login with online status update
  Future<String> loginUser({
    required String email,
    required String password,
  }) async {
    try {
      if (email.isEmpty || password.isEmpty) {
        return "Please enter all fields";
      }

      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = credential.user;
      if (user != null) {
        unawaited(_syncNotificationToken(user.uid));
      }

      return "success";
    } catch (e) {
      return e.toString();
    }
  }

  //Logout with online status update
  Future<void> signOut() async {
    // Marking the user offline is best-effort; it must never prevent sign-out.
    final user = _auth.currentUser;

    if (user != null) {
      try {
        await _firestore
            .collection('users')
            .doc(user.uid)
            .update({
              'isOnline': false,
              'lastSeen': FieldValue.serverTimestamp(),
            })
            .timeout(const Duration(seconds: 5));
      } catch (e) {
        debugPrint('[AUTH] Could not update offline status: $e');
      }
    }

    await _auth.signOut();
  }
}

final authMethodProvider = Provider<AuthMethod>((ref) {
  return AuthMethod();
});
