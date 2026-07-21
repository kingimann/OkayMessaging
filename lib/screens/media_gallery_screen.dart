import 'package:flutter/material.dart';

import '../models/message.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/linkable_text.dart';
import 'image_view_screen.dart';

/// Shows everything shared in a chat, split into Media (image messages shown
/// as a grid) and Links (messages containing URLs). Backed by [ChatStore] so
/// it reflects photos and links sent during the session.
class MediaGalleryScreen extends StatelessWidget {
  final String chatId;
  final String contactName;

  const MediaGalleryScreen({
    super.key,
    required this.chatId,
    required this.contactName,
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
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Media, links, and docs'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Media'), Tab(text: 'Links')],
          ),
        ),
        body: ListenableBuilder(
          listenable: ChatStore.instance,
          builder: (context, _) {
            final messages =
                ChatStore.instance.chatById(chatId)?.messages ?? const [];
            final media = messages.where((m) => m.isImage).toList();
            final links = messages
                .where((m) => !m.isImage && LinkableText.hasLink(m.text))
                .toList();
            return TabBarView(
              children: [
                _MediaGrid(media: media, contactName: contactName),
                _LinksList(links: links),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MediaGrid extends StatelessWidget {
  final List<Message> media;
  final String contactName;

  const _MediaGrid({required this.media, required this.contactName});

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) {
      return const _EmptyState(
        icon: Icons.photo_library_outlined,
        label: 'No media shared yet',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(3),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 3,
        crossAxisSpacing: 3,
      ),
      itemCount: media.length,
      itemBuilder: (context, i) {
        final message = media[i];
        final colors = MediaGalleryScreen
            ._gradients[message.imageSeed % MediaGalleryScreen._gradients.length];
        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ImageViewScreen(
                message: message,
                senderName: contactName,
              ),
            ),
          ),
          child: Hero(
            tag: 'photo_${message.id}',
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
              ),
              child: const Center(
                child: Icon(Icons.image, color: Colors.white70, size: 30),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LinksList extends StatelessWidget {
  final List<Message> links;

  const _LinksList({required this.links});

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) {
      return const _EmptyState(
        icon: Icons.link_outlined,
        label: 'No links shared yet',
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView.separated(
      itemCount: links.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: AppColors.tealGreenDark.withValues(alpha: 0.15),
            child: const Icon(Icons.link, color: AppColors.tealGreenDark),
          ),
          title: Text(links[i].text, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            DateFormatter.callLabel(links[i].time),
            style: TextStyle(
              color: isDark ? Colors.white54 : Colors.black45,
              fontSize: 12.5,
            ),
          ),
          onTap: () {},
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String label;

  const _EmptyState({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(label, style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
