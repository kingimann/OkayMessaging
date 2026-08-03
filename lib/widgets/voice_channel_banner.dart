import 'package:flutter/material.dart';

import '../main.dart' show rootNavigatorKey;
import '../models/community.dart';
import '../screens/communities.dart';
import '../state/call_service.dart';
import '../state/community_store.dart';
import '../state/voice_presence_store.dart';

/// The "you're still in voice" pill — the ReturnToCallBanner's shape for a
/// room instead of a call. Presence lives in [VoicePresenceStore] and
/// outlives the room screen, so this is what says so while you browse the
/// rest of the app, and the way back (or out).
///
/// Hidden on the room screen itself, and during a call — a call is the
/// louder fact and its banner owns the same spot.
class VoiceChannelBanner extends StatelessWidget {
  const VoiceChannelBanner({super.key});

  /// "Lounge · Studio", or just the channel when the server is gone.
  static String label(String? channelName, String? communityName) {
    if (channelName == null || channelName.isEmpty) return 'Voice channel';
    if (communityName == null || communityName.isEmpty) return channelName;
    return '$channelName · $communityName';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        VoicePresenceStore.instance,
        VoiceChannelScreen.onScreenFor,
        CallService.instance.current,
      ]),
      builder: (context, _) {
        final voice = VoicePresenceStore.instance;
        final channelId = voice.myChannelId;
        final communityId = voice.myCommunityId;
        if (channelId == null || communityId == null) {
          return const SizedBox.shrink();
        }
        if (VoiceChannelScreen.onScreenFor.value == channelId) {
          return const SizedBox.shrink();
        }
        if (CallService.instance.current.value != null) {
          return const SizedBox.shrink();
        }
        final community = CommunityStore.instance.byId(communityId);
        final channel = community?.channels
            .cast<Channel?>()
            .firstWhere((c) => c?.id == channelId, orElse: () => null);
        // The room can vanish under you — a moderator deleted the channel,
        // you left the server. Presence with no room is worth ending, not
        // drawing a pill to nowhere for.
        if (channel == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (voice.myChannelId == channelId) voice.leave();
          });
          return const SizedBox.shrink();
        }
        final others = voice.countIn(channelId) - 1;
        return Positioned(
          top: MediaQuery.of(context).padding.top + 6,
          left: 12,
          right: 12,
          child: Material(
            color: const Color(0xFF1DB954),
            borderRadius: BorderRadius.circular(26),
            elevation: 8,
            child: InkWell(
              borderRadius: BorderRadius.circular(26),
              onTap: () => rootNavigatorKey.currentState?.push(
                MaterialPageRoute(
                  builder: (_) => VoiceChannelScreen(
                      communityId: communityId, channelId: channelId),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
                child: Row(
                  children: [
                    const Icon(Icons.volume_up_rounded,
                        color: Colors.white, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${label(channel.name, community?.name)}'
                        '${others > 0 ? ' · $others here' : ''}'
                        ' — tap to return',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.call_end, color: Colors.white),
                      tooltip: 'Leave voice',
                      onPressed: voice.leave,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
