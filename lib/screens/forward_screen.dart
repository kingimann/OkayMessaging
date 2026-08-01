import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/user.dart';
import '../relay/relay_config.dart';
import '../relay/relay_service.dart';
import '../state/chat_store.dart';
import '../state/community_store.dart';
import '../state/score_store.dart';
import '../theme/app_theme.dart';
import '../widgets/user_avatar.dart';

/// Lets the user pick one or more conversations to send [text] — or, when
/// [place] is set, a shared-location card, or when [invite] is set, a
/// join-my-server card — into.
class ForwardScreen extends StatefulWidget {
  final String text;

  /// When set, a location message for this place is sent instead of [text].
  final ({double lat, double lng, String label})? place;

  /// When set, a server-invite message (this JSON snapshot) is sent instead.
  final String? invite;

  /// The photo to carry, for forwarding a picture rather than words.
  ///
  /// Without this, forwarding a photo forwarded its caption — which for a
  /// photo sent without one is nothing at all, so the other end got an empty
  /// bubble and no way to tell what had been meant.
  final String? imageUrl;

  const ForwardScreen(
      {super.key,
      required this.text,
      this.place,
      this.invite,
      this.imageUrl});

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

/// One server channel that can be forwarded into.
@immutable
class _ChannelDest {
  const _ChannelDest(this.communityId, this.communityName, this.channel);

  final String communityId;
  final String communityName;
  final Channel channel;

  String get key => '$communityId/${channel.id}';
}

class _ForwardScreenState extends State<ForwardScreen> {
  final Set<String> _selected = {};
  final Set<String> _selectedChannels = {};

  /// The channels this message could go to.
  ///
  /// Empty for a location or an invite: a channel bubble renders neither, so
  /// offering the channel would send a card nobody can see.
  List<_ChannelDest> get _channelDests {
    if (widget.place != null || widget.invite != null) return const [];
    final store = CommunityStore.instance;
    return [
      for (final community in store.communities)
        for (final channel in community.channels)
          if (store.canSendToChannel(community.id, channel.id))
            _ChannelDest(community.id, community.name, channel),
    ];
  }

  /// A real, number-identified peer (not a seeded demo contact or group), so
  /// the message can also be delivered over the relay.
  bool _isRealPeer(AppUser c) =>
      !c.isGroup && c.phone.isNotEmpty && c.id == c.phone;

  Message _buildMessage(String chatId, DateTime now) {
    final invite = widget.invite;
    if (invite != null) {
      return Message(
        id: 'inv_${chatId}_${now.microsecondsSinceEpoch}',
        text: widget.text,
        time: now,
        isMe: true,
        status: MessageStatus.sent,
        serverInvite: invite,
      );
    }
    final place = widget.place;
    if (place != null) {
      return Message(
        id: 'loc_${chatId}_${now.microsecondsSinceEpoch}',
        text: 'Shared location',
        time: now,
        isMe: true,
        status: MessageStatus.sent,
        isLocation: true,
        locationLat: place.lat,
        locationLng: place.lng,
        locationLabel: place.label,
      );
    }
    return _forwarded('fwd_${chatId}_${now.microsecondsSinceEpoch}', now);
  }

  Message _forwarded(String id, DateTime now) {
    final image = widget.imageUrl;
    return Message(
      id: id,
      text: widget.text,
      time: now,
      isMe: true,
      status: MessageStatus.sent,
      forwarded: true,
      isImage: image != null,
      imageUrl: image,
      imageSeed: now.microsecondsSinceEpoch % 6,
    );
  }

  void _send() {
    final store = ChatStore.instance;
    final now = DateTime.now();
    for (final id in _selected) {
      final Chat? chat = store.chatById(id);
      if (chat == null) continue;
      final message = _buildMessage(id, now);
      store.addMessage(id, message);
      // Also deliver over the relay when this is a real, reachable contact.
      if (RelayConfig.isEnabled && _isRealPeer(chat.contact)) {
        RelayService.instance.send(chat.contact.phone, message);
      }
    }
    for (final dest in _channelDests) {
      if (!_selectedChannels.contains(dest.key)) continue;
      final message =
          _forwarded('fwd_${dest.channel.id}_${now.microsecondsSinceEpoch}',
              now);
      CommunityStore.instance
          .postMessage(dest.communityId, dest.channel.id, message);
      // Same bus the channel's own composer uses, sealed with the server
      // secret — a forward is not a second, weaker path in.
      if (RelayConfig.isEnabled) {
        RelayService.instance.sendChannelMessage(
          dest.communityId,
          dest.channel.id,
          message,
          senderName: AppState.profile.value.name,
        );
      }
    }
    if (_selected.isNotEmpty || _selectedChannels.isNotEmpty) {
      ScoreStore.instance.recordFlag('forwarded');
    }
    final verb = widget.place != null || widget.invite != null
        ? 'Sent to'
        : 'Forwarded to';
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
          content: Text('$verb ${_countedDestinations(
        _selected.length,
        _selectedChannels.length,
      )}')),
    );
  }

  /// "2 chats", "1 channel", "2 chats and 1 channel" — never a bare number,
  /// because "Forwarded to 3" leaves the user counting back what they picked.
  static String _countedDestinations(int chats, int channels) {
    final parts = [
      if (chats > 0) '$chats chat${chats == 1 ? '' : 's'}',
      if (channels > 0) '$channels channel${channels == 1 ? '' : 's'}',
    ];
    return parts.join(' and ');
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            color: AppColors.subtle(context),
          ),
        ),
      );

  Widget _tick(bool selected) => selected
      ? Icon(Icons.check_circle, color: AppColors.accentOn(context))
      : Icon(Icons.circle_outlined, color: AppColors.subtle(context));

  @override
  Widget build(BuildContext context) {
    final chats = ChatStore.instance.chats;
    final channels = _channelDests;
    final total = _selected.length + _selectedChannels.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(total == 0
            ? (widget.place != null || widget.invite != null
                ? 'Send to...'
                : 'Forward to...')
            : '$total selected'),
      ),
      body: ListView(
        children: [
          if (channels.isNotEmpty) _sectionHeader('Chats'),
          for (final chat in chats)
            ListTile(
              leading: UserAvatar(user: chat.contact, radius: 24),
              title: Text(chat.contact.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: _tick(_selected.contains(chat.id)),
              onTap: () => setState(() {
                if (!_selected.remove(chat.id)) _selected.add(chat.id);
              }),
            ),
          if (channels.isNotEmpty) _sectionHeader('Channels'),
          for (final dest in channels)
            ListTile(
              leading: CircleAvatar(
                radius: 24,
                backgroundColor:
                    AppColors.accentOn(context).withValues(alpha: 0.14),
                child: Icon(Icons.tag,
                    size: 22, color: AppColors.accentOn(context)),
              ),
              title: Text(dest.channel.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(dest.communityName),
              trailing: _tick(_selectedChannels.contains(dest.key)),
              onTap: () => setState(() {
                if (!_selectedChannels.remove(dest.key)) {
                  _selectedChannels.add(dest.key);
                }
              }),
            ),
          // Room for the send button to sit over without covering a row.
          const SizedBox(height: 88),
        ],
      ),
      floatingActionButton: total == 0
          ? null
          : FloatingActionButton(
              backgroundColor: AppColors.accentOn(context),
              onPressed: _send,
              child: Icon(Icons.send, color: AppColors.onAccent(context)),
            ),
    );
  }
}
