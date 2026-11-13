import 'package:flutter/material.dart';
import 'package:yoked_in/widgets/cloudflare_media_image.dart';

void showFullScreenImage(String imageUrl, BuildContext context) {
  // Decode at screen size instead of the original camera resolution: a full
  // 12 MP bitmap is ~48 MB, enough to get the screen killed on its own.
  final mediaQuery = MediaQuery.of(context);
  final cacheWidth = (mediaQuery.size.width * mediaQuery.devicePixelRatio)
      .round()
      .clamp(600, 2400);

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          actions: [
            IconButton(
              onPressed: () {
                // Optional: Add download functionality
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Long press to save image')),
                );
              },
              icon: const Icon(Icons.more_vert),
            ),
          ],
        ),
        body: Center(
          child: InteractiveViewer(
              child: CloudflareMediaImage(
            imageUrl: imageUrl,
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            loading: const Center(
              child: CircularProgressIndicator(),
            ),
            error: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error,
                    color: Colors.white,
                    size: 50,
                  ),
                  Text(
                    'Failed to load image',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          )),
        ),
      ),
    ),
  );
}
