
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:image_picker/image_picker.dart';
import 'package:yoked_in/chat/user_profile_model.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';

/// Manages the signed-in user's profile data and profile photo.
class ProfileNotifier extends StateNotifier<ProfileState> {
  late final StreamSubscription<User?> _authSubscription;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _profileSubscription;

  ProfileNotifier() : super(ProfileState(isLoading: true)) {
    _listenToAuthChanges();
  }

  /// Listen for Firebase Authentication changes.
  void _listenToAuthChanges() {
    _authSubscription =
        FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        _stopListeningToProfile();

        state = ProfileState(isLoading: false);
        return;
      }

      if (state.userId != user.uid) {
        state = ProfileState(
          userId: user.uid,
          isLoading: true,
        );
      }

      _watchUserProfile(user);
    });
  }

  /// Subscribe to real-time changes in users/{uid}.
  ///
  /// When photoURL, name, email or createdAt changes in Firestore,
  /// the profile state updates automatically.
  void _watchUserProfile(User user) {
    _stopListeningToProfile();

    _profileSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen(
      (doc) {
        if (!mounted || FirebaseAuth.instance.currentUser?.uid != user.uid) {
          return;
        }

        if (!doc.exists) {
          state = ProfileState(
            userId: user.uid,
            isLoading: false,
            isUploading: state.isUploading,
          );
          return;
        }

        final data = doc.data() ?? <String, dynamic>{};

        final createdAtValue = data['createdAt'];

        state = ProfileState(
          photoUrl: data['photoURL'] as String?,
          name: data['name'] as String? ?? '',
          email: data['email'] as String? ?? user.email ?? '',
          createdAt: createdAtValue is Timestamp
              ? createdAtValue.toDate()
              : null,
          userId: user.uid,
          isLoading: false,
          isUploading: state.isUploading,
        );
      },
      onError: (Object error) {
        if (!mounted || FirebaseAuth.instance.currentUser?.uid != user.uid) {
          return;
        }

        state = state.copyWith(isLoading: false);
      },
    );
  }

  /// Stop listening to the previous user's profile document.
  void _stopListeningToProfile() {
    _profileSubscription?.cancel();
    _profileSubscription = null;
  }

  /// Load the signed-in user's profile from Firestore.
  ///
  /// Retained for compatibility with existing callers of loadUserData().
  /// The real-time listener also keeps this data up to date.
  Future<void> loadUserData([User? user]) async {
    final currentUser = user ?? FirebaseAuth.instance.currentUser;

    if (currentUser == null) {
      state = ProfileState(isLoading: false);
      return;
    }

    state = state.copyWith(isLoading: true);

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != currentUser.uid) {
        return;
      }

      if (doc.exists) {
        final data = doc.data() ?? <String, dynamic>{};
        final createdAtValue = data['createdAt'];

        state = ProfileState(
          photoUrl: data['photoURL'] as String?,
          name: data['name'] as String? ?? '',
          email: data['email'] as String? ?? currentUser.email ?? '',
          createdAt: createdAtValue is Timestamp
              ? createdAtValue.toDate()
              : null,
          userId: currentUser.uid,
          isLoading: false,
          isUploading: state.isUploading,
        );
      } else {
        state = ProfileState(
          userId: currentUser.uid,
          isLoading: false,
          isUploading: state.isUploading,
        );
      }
    } catch (error) {
      if (!mounted ||
          FirebaseAuth.instance.currentUser?.uid != currentUser.uid) {
        return;
      }

      state = state.copyWith(isLoading: false);
    }
  }

  /// Refresh the current user's profile.
  void refresh() {
    loadUserData();
  }

  /// Pick a profile photo and upload it to Cloudflare R2.
  ///
  /// The returned media URL is saved in users/{uid}.photoURL.
  Future<bool> updateProfilePicture() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return false;
    }

    final picker = ImagePicker();

    final XFile? pickedFile;

    try {
      pickedFile = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1200,
      );
    } catch (error) {
      return false;
    }

    if (pickedFile == null) {
      return false;
    }

    state = state.copyWith(isUploading: true);

    try {
      final uploadResult =
          await CloudflareMediaService.instance.uploadFile(pickedFile);

      final newUrl = uploadResult['url'] as String;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update({
        'photoURL': newUrl,
      });

      if (!mounted || FirebaseAuth.instance.currentUser?.uid != user.uid) {
        return true;
      }

      // Update local state immediately. The Firestore listener will
      // also receive the saved URL and keep the profile synchronized.
      state = state.copyWith(
        photoUrl: newUrl,
        isUploading: false,
      );

      return true;
    } catch (error) {
      if (mounted && FirebaseAuth.instance.currentUser?.uid == user.uid) {
        state = state.copyWith(isUploading: false);
      }

      return false;
    }
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    _stopListeningToProfile();
    super.dispose();
  }
}

/// Riverpod provider for the user's profile.
final profileProvider =
    StateNotifierProvider<ProfileNotifier, ProfileState>((ref) {
  return ProfileNotifier();
});
