import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:yoked_in/services/cloudflare_media_service.dart';

class CloudflareMediaImage extends StatefulWidget {
  const CloudflareMediaImage({
    super.key,
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.loading,
    this.error,
  });

  final String imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? loading;
  final Widget? error;

  @override
  State<CloudflareMediaImage> createState() =>
      _CloudflareMediaImageState();
}

class _CloudflareMediaImageState extends State<CloudflareMediaImage> {
  late Future<Uint8List> _imageFuture;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant CloudflareMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.imageUrl != widget.imageUrl) {
      _loadImage();
    }
  }

  void _loadImage() {
    _imageFuture =
        CloudflareMediaService.instance.downloadMedia(widget.imageUrl);
  }

  @override
  Widget build(BuildContext context) {
    final cachedBytes =
        CloudflareMediaService.instance.getCachedImage(widget.imageUrl);
    if (cachedBytes != null) {
      return Image.memory(
        cachedBytes,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => widget.error ??
            const Center(child: Icon(Icons.broken_image, color: Colors.grey)),
      );
    }

    return FutureBuilder<Uint8List>(
      future: _imageFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return widget.loading ??
              SizedBox(
                width: widget.width,
                height: widget.height ?? 200,
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return widget.error ??
              SizedBox(
                width: widget.width,
                height: widget.height ?? 200,
                child: const Center(
                  child: Icon(
                    Icons.broken_image,
                    size: 50,
                    color: Colors.grey,
                  ),
                ),
              );
        }

        return Image.memory(
          snapshot.data!,
          fit: widget.fit,
          width: widget.width,
          height: widget.height,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            return widget.error ??
                const Center(
                  child: Icon(
                    Icons.broken_image,
                    size: 50,
                    color: Colors.grey,
                  ),
                );
          },
        );
      },
    );
  }
}