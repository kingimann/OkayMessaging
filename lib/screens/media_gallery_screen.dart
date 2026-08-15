import 'package:flutter/material.dart';

import '../models/message.dart';
import '../state/chat_store.dart';
import '../theme/app_theme.dart';
import '../utils/date_formatter.dart';
import '../widgets/chat_photo.dart';
import '../widgets/empty_state.dart';
import '../widgets/linkable_text.dart';
import '../widgets/pull_to_refresh.dart';
import 'image_view_screen.dart';
import 'in_app_web_screen.dart';
import 'location_map_screen.dart';

/// The chat's pinboard: everything worth coming back to, without scrolling
/// for it — pinned messages, photos, links, places and files, each in its
/// own tab. Backed by [ChatStore] so it reflects what's sent during the
/// session.
///
/// View-once messages are deliberately absent from every tab: a board that
/// listed a ghost message or a view-once photo would be a second door into
/// content that promised exactly one viewing.
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
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pinboard'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Pinned'),
              Tab(text: 'Media'),
              Tab(text: 'Links'),
              Tab(text: 'Places'),
              Tab(text: 'Files'),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: ChatStore.instance,
          builder: (context, _) {
            final chat = ChatStore.instance.chatById(chatId);
            final messages = chat?.messages ?? const <Message>[];
            final byId = {for (final m in messages) m.id: m};
            final pinned = [
              for (final id in chat?.pinnedMessageIds ?? const <String>[])
                if (byId[id] != null) byId[id]!
            ];
            final media =
                messages.where((m) => m.isImage && !m.viewOnce).toList();
            final links = messages
                .where((m) =>
                    !m.isImage &&
                    !m.viewOnce &&
                    !m.isDeleted &&
                    LinkableText.hasLink(m.text))
                .toList();
            final places =
                messages.where((m) => m.isLocation && !m.isDeleted).toList();
            final files =
                messages.where((m) => m.isFile && !m.isDeleted).toList();
            return TabBarView(
              children: [
                _PinnedList(chatId: chatId, pinned: pinned),
                _MediaGrid(media: media, contactName: contactName),
                _LinksList(links: links),
                _PlacesList(places: places),
                _FilesList(files: files),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// What a pinned message reads as in a list, when its own text is not enough.
String pinboardPreview(Message m) {
  if (m.isDeleted) return 'Deleted message';
  if (m.isImage) return '📷 Photo';
  if (m.isLocation) {
    final label = m.locationLabel ?? '';
    return label.isEmpty ? '📍 Location' : '📍 $label';
  }
  if (m.isFile) return '📎 ${m.fileName}';
  if (m.isForm) return '📋 ${m.formTitle}';
  if (m.isPoll) return '📊 ${m.pollQuestion}';
  if (m.isContact) return '👤 ${m.contactName ?? 'Contact'}';
  if (m.isVoice) return '🎤 Voice message';
  return m.text;
}

class _PinnedList extends StatelessWidget {
  final String chatId;
  final List<Message> pinned;

  const _PinnedList({required this.chatId, required this.pinned});

  @override
  Widget build(BuildContext context) {
    if (pinned.isEmpty) {
      return PullToRefresh.emptyState(
        child: const _EmptyState(
          icon: Icons.push_pin_outlined,
          label: 'Nothing pinned yet',
          caption: 'Hold a message and pin it to keep it here.',
        ),
      );
    }
    return PullToRefresh(
      child: ListView.separated(
        itemCount: pinned.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final m = pinned[i];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  AppColors.accentOn(context).withValues(alpha: 0.15),
              child: Icon(Icons.push_pin,
                  color: AppColors.accentOn(context), size: 20),
            ),
            title: Text(pinboardPreview(m),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(DateFormatter.callLabel(m.time),
                style: TextStyle(
                    color: AppColors.subtle(context), fontSize: 12.5)),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Unpin',
              onPressed: () =>
                  ChatStore.instance.unpinMessage(chatId, m.id),
            ),
          );
        },
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
      return PullToRefresh.emptyState(
        child: const _EmptyState(
          icon: Icons.photo_library_outlined,
          label: 'No media shared yet',
        ),
      );
    }
    return PullToRefresh(
      child: GridView.builder(
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
                  // Same two refusals as the chat transcript this gallery is
                  // built from — it is the same photos, so the same answer.
                  canSave: !message.viewOnce && !message.protected,
                ),
              ),
            ),
            child: Hero(
              tag: 'photo_${message.id}',
              child: message.imageUrl != null
                  ? ChatPhoto(
                      url: message.imageUrl!,
                      errorBuilder: (_) => _gradientTile(colors),
                    )
                  : _gradientTile(colors),
            ),
          );
        },
      ),
    );
  }
}

/// The placeholder tile for demo photos (no real bytes to show).
Widget _gradientTile(List<Color> colors) => Container(
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
    );

class _LinksList extends StatelessWidget {
  final List<Message> links;

  const _LinksList({required this.links});

  /// The first URL in [text], with the scheme a bare www. link is missing.
  static String? firstUrl(String text) {
    final match = LinkableText.urlPattern.firstMatch(text)?.group(0);
    if (match == null) return null;
    return match.startsWith('www.') ? 'https://$match' : match;
  }

  @override
  Widget build(BuildContext context) {
    if (links.isEmpty) {
      return PullToRefresh.emptyState(
        child: const _EmptyState(
          icon: Icons.link_outlined,
          label: 'No links shared yet',
        ),
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return PullToRefresh(
      child: ListView.separated(
        itemCount: links.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: AppColors.accentOn(context).withValues(alpha: 0.15),
              child: Icon(Icons.link, color: AppColors.accentOn(context)),
            ),
            title: Text(links[i].text, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              DateFormatter.callLabel(links[i].time),
              style: TextStyle(
                color: isDark ? Colors.white54 : Colors.black45,
                fontSize: 12.5,
              ),
            ),
            // On one of the app's own screens, never a browser hand-off —
            // the same rule every link in the app follows.
            onTap: () {
              final url = firstUrl(links[i].text);
              if (url != null) InAppWebScreen.open(context, url);
            },
          );
        },
      ),
    );
  }
}

class _PlacesList extends StatelessWidget {
  final List<Message> places;

  const _PlacesList({required this.places});

  @override
  Widget build(BuildContext context) {
    if (places.isEmpty) {
      return PullToRefresh.emptyState(
        child: const _EmptyState(
          icon: Icons.place_outlined,
          label: 'No places shared yet',
          caption: 'Shared locations and addresses collect here.',
        ),
      );
    }
    return PullToRefresh(
      child: ListView.separated(
        itemCount: places.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final m = places[i];
          final label = m.locationLabel ?? '';
          return ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  AppColors.accentOn(context).withValues(alpha: 0.15),
              child:
                  Icon(Icons.place, color: AppColors.accentOn(context)),
            ),
            title: Text(label.isEmpty ? 'Shared location' : label,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(DateFormatter.callLabel(m.time),
                style: TextStyle(
                    color: AppColors.subtle(context), fontSize: 12.5)),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => LocationMapScreen(
                  lat: m.locationLat ?? 0,
                  lng: m.locationLng ?? 0,
                  label: label,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FilesList extends StatelessWidget {
  final List<Message> files;

  const _FilesList({required this.files});

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) {
      return PullToRefresh.emptyState(
        child: const _EmptyState(
          icon: Icons.insert_drive_file_outlined,
          label: 'No files shared yet',
          caption: 'Documents and videos saved from this chat collect here.',
        ),
      );
    }
    return PullToRefresh(
      child: ListView.separated(
        itemCount: files.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final m = files[i];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor:
                  AppColors.accentOn(context).withValues(alpha: 0.15),
              child: Icon(Icons.insert_drive_file,
                  color: AppColors.accentOn(context)),
            ),
            title: Text(m.fileName.isEmpty ? 'File' : m.fileName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            // The message text carries the human-readable line, including
            // where the file was saved.
            subtitle: Text(m.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppColors.subtle(context), fontSize: 12.5)),
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? caption;

  const _EmptyState({required this.icon, required this.label, this.caption});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      title: label,
      caption: caption ?? 'Everything shared in this chat collects here.',
    );
  }
}
