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
    this.cacheWidth,
    this.loading,
    this.error,
  });

  final String imageUrl;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// Maximum decoded width in physical pixels. Without it every photo is
  /// decoded at its original camera resolution (a 12 MP photo is ~48 MB in
  /// memory), which is what makes a photo-heavy chat run out of memory.
  final int? cacheWidth;
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

  /// Decode bound for this image, in physical pixels.
  int _decodeWidth(BuildContext context) {
    final explicit = widget.cacheWidth;
    if (explicit != null && explicit > 0) return explicit;

    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final logical = (widget.width != null && widget.width! > 0)
        ? widget.width!
        : MediaQuery.sizeOf(context).width;

    final pixels = (logical * pixelRatio).round();
    if (pixels < 64) return 64;
    // A single bubble never needs more than a 1600 px decode.
    return pixels > 1600 ? 1600 : pixels;
  }

  @override
  Widget build(BuildContext context) {
    final decodeWidth = _decodeWidth(context);
    final cachedBytes =
        CloudflareMediaService.instance.getCachedImage(widget.imageUrl);
    if (cachedBytes != null) {
      return Image.memory(
        cachedBytes,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: decodeWidth,
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
          cacheWidth: decodeWidth,
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