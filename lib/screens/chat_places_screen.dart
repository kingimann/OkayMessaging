import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/message.dart';
import '../state/chat_store.dart';
import '../utils/date_formatter.dart';
import '../widgets/osm_map.dart';
import 'route_map_screen.dart';

/// All the locations ever shared in one conversation, plotted on a single
/// map. Tap a pin to see who shared it and get directions.
class ChatPlacesScreen extends StatefulWidget {
  final String chatId;
  final String contactName;

  const ChatPlacesScreen({
    super.key,
    required this.chatId,
    required this.contactName,
  });

  @override
  State<ChatPlacesScreen> createState() => _ChatPlacesScreenState();
}

class _ChatPlacesScreenState extends State<ChatPlacesScreen> {
  final MapController _map = MapController();
  Message? _selected;
  bool _fitted = false;

  List<Message> _places() {
    final chat = ChatStore.instance.chatById(widget.chatId);
    if (chat == null) return const [];
    return chat.messages
        .where((m) =>
            m.isLocation && m.locationLat != null && m.locationLng != null)
        .toList();
  }

  void _fitOnce(List<Message> places) {
    if (_fitted || places.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (places.length == 1) {
        _map.move(
            LatLng(places.first.locationLat!, places.first.locationLng!), 14);
        return;
      }
      _map.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([
            for (final m in places) LatLng(m.locationLat!, m.locationLng!),
          ]),
          padding: const EdgeInsets.fromLTRB(60, 80, 60, 160),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shared places')),
      body: ListenableBuilder(
        listenable: ChatStore.instance,
        builder: (context, _) {
          final places = _places();
          if (places.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.place_outlined,
                        size: 56, color: Colors.grey.shade500),
                    const SizedBox(height: 12),
                    Text(
                      'No places shared in this chat yet',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Locations either of you share will show up here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
            );
          }
          _fitOnce(places);
          final selected = _selected;
          return Stack(
            children: [
              FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCenter: LatLng(
                      places.first.locationLat!, places.first.locationLng!),
                  initialZoom: 13,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: [
                  const LiveTileLayer(),
                  MarkerLayer(
                    markers: [
                      for (final m in places)
                        Marker(
                          point: LatLng(m.locationLat!, m.locationLng!),
                          width: 40,
                          height: 40,
                          alignment: Alignment.topCenter,
                          child: GestureDetector(
                            onTap: () => setState(() => _selected = m),
                            child: Icon(
                              Icons.location_pin,
                              size: 40,
                              color: m == selected
                                  ? const Color(0xFF0A84FF)
                                  : const Color(0xFFEB4B3F),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const LiveAttribution(),
                ],
              ),
              MapControls(controller: _map, bottom: selected == null ? 96 : 200),
              if (selected != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 20,
                  child: SafeArea(child: _placeCard(context, selected)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _placeCard(BuildContext context, Message m) {
    final label = (m.locationLabel?.trim().isNotEmpty ?? false)
        ? m.locationLabel!.trim()
        : 'Shared location';
    final who = m.isMe ? 'You' : widget.contactName;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    'Shared by $who · ${DateFormatter.messageTime(m.time)}',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => RouteMapScreen(
                          dest: LatLng(m.locationLat!, m.locationLng!),
                          label: label,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.directions, size: 18),
                    label: const Text('Directions'),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear',
              onPressed: () => setState(() => _selected = null),
            ),
          ],
        ),
      ),
    );
  }
}
