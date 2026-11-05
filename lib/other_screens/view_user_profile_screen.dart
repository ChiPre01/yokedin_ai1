import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';
import 'package:yoked_in/widgets/full_screen_image.dart';

/// Read-only view of another user's public profile. Logout is intentionally
/// available only on the signed-in user's own Profile tab.
class ViewUserProfileScreen extends StatelessWidget {
  final String userId;

  const ViewUserProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        title: const Text('Profile'),
      ),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: FirebaseFirestore.instance.collection('users').doc(userId).get(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('Unable to load this profile.'));
          }
          final data = snapshot.data!.data() ?? <String, dynamic>{};
          final name = (data['name'] as String?)?.trim();
          final email = (data['email'] as String?)?.trim();
          final photoUrl = (data['photoURL'] as String?)?.trim() ?? '';
          final createdAt = data['createdAt'];
          DateTime? joined;
          if (createdAt is Timestamp) joined = createdAt.toDate();
          final cloudflare = photoUrl.isNotEmpty && _isCloudflareUrl(photoUrl);

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: photoUrl.isEmpty ? null : () => showFullScreenImage(photoUrl, context),
                    child: CircleAvatar(
                      radius: 64,
                      backgroundColor: Colors.grey.shade200,
                      child: ClipOval(
                        child: photoUrl.isEmpty
                            ? const SizedBox(width: 128, height: 128, child: Icon(Icons.person, size: 58, color: Colors.grey))
                            : cloudflare
                                ? CloudflareMediaImage(
                                    imageUrl: photoUrl,
                                    width: 128,
                                    height: 128,
                                    fit: BoxFit.cover,
                                    loading: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                                    error: const Icon(Icons.person, size: 58, color: Colors.grey),
                                  )
                                : Image.network(
                                    photoUrl,
                                    width: 128,
                                    height: 128,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.person, size: 58, color: Colors.grey),
                                  ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(name?.isNotEmpty == true ? name! : 'No Name', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  Text(email?.isNotEmpty == true ? email! : 'No Email', style: const TextStyle(fontSize: 16, color: Colors.black54), textAlign: TextAlign.center),
                  const SizedBox(height: 6),
                  Text('Joined ${joined == null ? 'Joined date not available' : '${_month(joined.month)} ${joined.day}, ${joined.year}'}', style: const TextStyle(fontSize: 15, color: Colors.black54), textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  bool _isCloudflareUrl(String value) {
    final uri = Uri.tryParse(value);
    final base = Uri.tryParse(CloudflareMediaService.baseUrl);
    return uri != null && base != null && uri.scheme == 'https' && uri.host == base.host && uri.path.startsWith('/media/');
  }

  String _month(int month) => const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][month - 1];
}
