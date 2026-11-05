
/// Profile state model.
class ProfileState {
  final String? photoUrl;
  final String? name;
  final String? email;
  final bool isLoading;
  final bool isUploading;
  final DateTime? createdAt;
  final String? userId;

  const ProfileState({
    this.photoUrl,
    this.name,
    this.createdAt,
    this.email,
    this.isLoading = false,
    this.isUploading = false,
    this.userId,
  });

  ProfileState copyWith({
    String? photoUrl,
    String? name,
    String? email,
    DateTime? createdAt,
    bool? isLoading,
    bool? isUploading,
    String? userId,
    bool clearPhotoUrl = false,
    bool clearName = false,
    bool clearEmail = false,
    bool clearCreatedAt = false,
    bool clearUserId = false,
  }) {
    return ProfileState(
      photoUrl: clearPhotoUrl ? null : photoUrl ?? this.photoUrl,
      name: clearName ? null : name ?? this.name,
      email: clearEmail ? null : email ?? this.email,
      createdAt: clearCreatedAt ? null : createdAt ?? this.createdAt,
      isLoading: isLoading ?? this.isLoading,
      isUploading: isUploading ?? this.isUploading,
      userId: clearUserId ? null : userId ?? this.userId,
    );
  }
}
