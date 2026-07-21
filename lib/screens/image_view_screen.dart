import 'package:flutter/material.dart';

import '../models/message.dart';
import '../utils/date_formatter.dart';

/// A full-screen viewer for an image [Message], opened by tapping a photo
/// bubble. The gradient placeholder animates up via a shared [Hero] and can
/// be pinch-zoomed / panned like a real photo.
class ImageViewScreen extends StatelessWidget {
  final Message message;
  final String senderName;

  const ImageViewScreen({
    super.key,
    required this.message,
    required this.senderName,
  });

  static const _gradients = [
    [Color(0xFF667EEA), Color(0xFF764BA2)],
    [Color(0xFFFF9A9E), Color(0xFFFAD0C4)],
    [Color(0xFF43CEA2), Color(0xFF185A9D)],
    [Color(0xFFF6D365), Color(0xFFFDA085)],
    [Color(0xFF30CFD0), Color(0xFF330867)],
    [Color(0xFFA8EDEA), Color(0xFFFED6E3)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _gradients[message.imageSeed % _gradients.length];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              message.isMe ? 'You' : senderName,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              DateFormatter.messageDayHeader(message.time),
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
      ),
      body: Center(
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Hero(
            tag: 'photo_${message.id}',
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: AspectRatio(
                aspectRatio: 220 / 260,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: colors,
                    ),
                  ),
                  child: const Center(
                    child: Icon(Icons.image, color: Colors.white70, size: 96),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
