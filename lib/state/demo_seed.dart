import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/user.dart';
import 'call_log.dart';
import 'chat_store.dart';
import 'community_store.dart';
import 'feed_store.dart';

/// Screenshot fixtures, behind an explicit build flag.
///
/// The no-fake-data rule stands: a release build in a user's hands never
/// shows invented people or activity. This tool keeps that rule by
/// EXISTING only in a build made with `--dart-define=DEMO_SEED=true` —
/// the owner's own screenshot build, never the one submitted to the App
/// Store — and by saying what it is on its own Settings section rather
/// than hiding behind a gesture.
///
/// Everything it seeds is LOCAL. It goes through the same apply paths the
/// relay uses for *incoming* content, and never the send paths — nothing
/// here is broadcast, uploaded, or queued for anyone else's device, and
/// the public newsfeed is deliberately untouched because its posts live in
/// a real shared table where fake content would be fake for everyone.
class DemoSeed {
  DemoSeed._();

  /// Compile-time gate. Without the flag the Settings section is not
  /// built and nothing here is reachable.
  static const bool enabled =
      bool.fromEnvironment('DEMO_SEED', defaultValue: false);

  static const _serverName = 'Design Club';

  /// Deterministic ids so [clear] can undo exactly what [populate] did.
  static const _postIds = [
    'demo_p1', 'demo_p2', 'demo_p3', 'demo_p4', 'demo_l1', 'demo_l2',
  ];

  /// Fills the app with presentable content: conversations, a call
  /// history, and a server with a feed and marketplace listings.
  /// Idempotent — tapping twice does not double anything.
  static void populate() {
    for (final chat in MockData.chats()) {
      if (ChatStore.instance.chatById(chat.id) == null) {
        ChatStore.instance.upsert(chat);
      }
    }
    // One business conversation, so the storefront surfaces (chat header,
    // list marker, contact card) are visible in screenshots.
    if (ChatStore.instance.chatById('demo_biz') == null) {
      ChatStore.instance.upsert(Chat(
        id: 'demo_biz',
        contact: const AppUser(
          id: '+15550100042',
          name: 'Fern & Stone Café',
          avatarColor: '#8D6E63',
          about: 'Espresso, bakes, and a quiet corner.',
          phone: '+15550100042',
          username: 'fernandstone',
          isBusiness: true,
          businessCategory: 'Food & drink',
          businessHours: 'Mon–Sat 7–4',
        ),
        messages: [
          Message(
            id: 'demo_biz_m1',
            text: 'Your order is ready for pickup — see you soon! ☕',
            time: DateTime.now().subtract(const Duration(minutes: 40)),
            isMe: false,
            status: MessageStatus.delivered,
          ),
        ],
      ));
    }
    final log = CallLog.instance;
    for (final call in MockData.calls()) {
      if (!log.records.any((r) => r.id == call.id)) log.add(call);
    }

    final store = CommunityStore.instance;
    Community? community;
    for (final c in store.communities) {
      if (c.name == _serverName) {
        community = c;
        break;
      }
    }
    community ??= store.createCommunity(
      _serverName,
      icon: '🎨',
      color: '#7A5CFF',
      description: 'Weekly crits, fonts, and found design',
    );
    final cid = community.id;
    final feed = FeedStore.instance;
    DateTime ago(Duration d) => DateTime.now().subtract(d);
    final posts = [
      FeedPost(
        id: 'demo_p1',
        communityId: cid,
        authorName: 'Alice Bennett',
        authorUsername: 'aliceb',
        authorVerified: true,
        time: ago(const Duration(minutes: 25)),
        text: 'Posted the new poster set — fully recycled stock this '
            'time. Crit thread below 👇',
        likes: 14,
        replies: 3,
      ),
      FeedPost(
        id: 'demo_p2',
        communityId: cid,
        authorName: 'Frank Moore',
        authorUsername: 'frankm',
        time: ago(const Duration(hours: 2)),
        text: 'Hot take: the best app icons still read at 16 px.',
        likes: 9,
        replies: 5,
      ),
      FeedPost(
        id: 'demo_p3',
        communityId: cid,
        authorName: 'Grace Lin',
        authorUsername: 'gracel',
        time: ago(const Duration(hours: 5)),
        text: 'Type walk from this morning — found a hand-painted '
            'ampersand worth the whole trip.',
        likes: 21,
        replies: 2,
      ),
      FeedPost(
        id: 'demo_p4',
        communityId: cid,
        authorName: 'Erin Walsh',
        authorUsername: 'erinw',
        time: ago(const Duration(days: 1)),
        text: 'Friday crit moved to 3pm — bring one thing you shipped '
            'and one thing you killed.',
        likes: 6,
        replies: 1,
      ),
      FeedPost(
        id: 'demo_l1',
        communityId: cid,
        authorName: 'Alice Bennett',
        authorUsername: 'aliceb',
        authorVerified: true,
        time: ago(const Duration(hours: 8)),
        text: 'Mechanical keyboard, barely used. Cream keycaps, '
            'silent switches.',
        priceCents: 6500,
        listingCategory: 'Electronics',
        listingCondition: 'Like new',
      ),
      FeedPost(
        id: 'demo_l2',
        communityId: cid,
        authorName: 'Frank Moore',
        authorUsername: 'frankm',
        time: ago(const Duration(days: 2)),
        text: 'City bike, freshly tuned. Pickup only.',
        priceCents: 12000,
        listingCategory: 'Sports',
        listingCondition: 'Good',
      ),
    ];
    for (final p in posts) {
      feed.addRemote(p);
    }
  }

  /// Removes exactly what [populate] added — the mock chats also clear
  /// themselves on the next launch (the store strips `c_` ids on load),
  /// but nobody should have to know that to get their device back.
  static void clear() {
    for (final chat in MockData.chats()) {
      ChatStore.instance.deleteChat(chat.id);
    }
    ChatStore.instance.deleteChat('demo_biz');
    for (final call in MockData.calls()) {
      CallLog.instance.remove(call.id);
    }
    for (final id in _postIds) {
      FeedStore.instance.deletePost(id);
    }
    final store = CommunityStore.instance;
    for (final c in store.communities.where((c) => c.name == _serverName)) {
      store.deleteCommunity(c.id);
      break;
    }
  }
}
