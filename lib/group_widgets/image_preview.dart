import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class ImagePreviewDialog extends StatefulWidget {
  final XFile imageFile;

  const ImagePreviewDialog({
    super.key,
    required this.imageFile,
  });

  @override
  State<ImagePreviewDialog> createState() => _ImagePreviewDialogState();
}

class _ImagePreviewDialogState extends State<ImagePreviewDialog> {
  final TextEditingController _captionController = TextEditingController();

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Send Image?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FutureBuilder<Uint8List>(
              future: widget.imageFile.readAsBytes(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 200,
                    child: Center(
                      child: CircularProgressIndicator(),
                    ),
                  );
                }

                if (snapshot.hasError || !snapshot.hasData) {
                  return const SizedBox(
                    height: 200,
                    child: Center(
                      child: Text('Unable to preview this image.'),
                    ),
                  );
                }

                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    snapshot.data!,
                    height: 250,
                    fit: BoxFit.contain,
                    cacheWidth: (MediaQuery.sizeOf(context).width *
                            MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(320, 1600),
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _captionController,
              maxLines: 3,
              minLines: 1,
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Add a caption...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.pop(context, _captionController.text.trim());
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}