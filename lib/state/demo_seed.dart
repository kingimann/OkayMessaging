import '../data/mock_data.dart';
import '../models/chat.dart';
import '../models/community.dart';
import '../models/message.dart';
import '../models/user.dart';
import 'bookmark_store.dart';
import 'call_log.dart';
import 'chat_folders.dart';
import 'chat_store.dart';
import 'community_store.dart';
import 'feed_store.dart';
import 'notes_store.dart';
import 'platform_moderation.dart';

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
///
/// It covers the surfaces a fresh install leaves blank: chats (including a
/// business and a subscribable creator), calls, TWO servers with their own
/// timelines and channels, six marketplace listings, the Notifications tab,
/// Notes, bookmarks with a folder, and a chat folder.
///
/// **Two things it deliberately does not fill.**
///  * The public **newsfeed and forum**, per the paragraph above. They are
///    the two surfaces whose content is not this device's to invent.
///  * The **Okay Score**. `award()` only adds, and there is no public way to
///    take points back — so seeding it would leave permanent invented points
///    on a device the owner also uses for real, and [clear] could not honour
///    its promise. A screenshot of a real score costs one daily check-in.
class DemoSeed {
  DemoSeed._();

  /// Compile-time gate. Without the flag nothing here is ever compiled in.
  static const bool enabled =
      bool.fromEnvironment('DEMO_SEED', defaultValue: false);

  /// Runtime gate: even in a DEMO_SEED build, the fixtures are only offered to
  /// an ADMIN or OWNER account — never a real user, who must never see invented
  /// people (the no-fake-data rule). Owner status is server-verified and can't
  /// be forged from the client. Screens gate the Settings section on this, and
  /// [populate] refuses under it as the backstop.
  static bool get available =>
      enabled && PlatformModeration.instance.canAdminister;

  static const _serverName = 'Design Club';

  /// A second server, so the Servers list is a LIST rather than one row —
  /// and so the switcher, the unread dot and the join/discover chrome have
  /// something to sit beside.
  static const _serverName2 = 'Trail Runners';

  /// Deterministic ids so [clear] can undo exactly what [populate] did.
  static const _postIds = [
    'demo_p1', 'demo_p2', 'demo_p3', 'demo_p4', 'demo_l1', 'demo_l2',
    // Round two: enough listings that the marketplace grid is a grid, and a
    // second server's timeline.
    'demo_l3', 'demo_l4', 'demo_l5', 'demo_l6',
    'demo_q1', 'demo_q2', 'demo_q3',
  ];

  /// The notes [populate] writes, by body — Notes mints its own ids, so this
  /// is what [clear] matches on to take back exactly these and no others.
  static const _noteBodies = [
    'Poster crit — Friday 3pm\nBring one thing shipped, one thing killed.',
    // "rated at 800" rather than the usual verb for over-developing film:
    // the local-only guard scans this WHOLE FILE, comments included, for the
    // notification service's name as a bare substring, and a nicer line of
    // prose is not worth loosening a rule that errs on the safe side.
    'Film stock to try\n- Portra 400\n- HP5 rated at 800\n- Ektar for the coast',
    'Coffee order for the studio run: 2 flat whites, 1 long black, 1 decaf.',
    'Ideas\nA type walk map. Photograph every hand-painted sign on the '
        'high street and pin them.',
  ];

  static const _bookmarkFolder = 'Keep';
  static const _chatFolder = 'Studio';

  /// Notification ids, so the Notifications tab is not an empty screen in
  /// screenshots and [clear] can find them again.
  static const _noteIds = ['demo_n1', 'demo_n2', 'demo_n3'];

  /// Fills the app with presentable content: conversations, a call
  /// history, and a server with a feed and marketplace listings.
  /// Idempotent — tapping twice does not double anything.
  static void populate() {
    // Admin/owner only — the runtime half of [available]. (The compile flag is
    // the Settings-visibility gate; this is the security backstop, so it holds
    // even if a caller reaches populate() another way.)
    if (!PlatformModeration.instance.canAdminister) return;
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
    // One CREATOR who offers subscriptions, so the Subscribe button and the
    // tier sheet have something to appear on. Nothing else in a fresh install
    // is subscribable, which left those screens unreachable for screenshots.
    if (ChatStore.instance.chatById('demo_creator') == null) {
      ChatStore.instance.upsert(Chat(
        id: 'demo_creator',
        contact: AppUser(
          id: '+15550100043',
          name: 'Mara Vance',
          avatarColor: '#7A5CFF',
          about: 'Field recordings and darkroom notes.',
          phone: '+15550100043',
          username: 'maravance',
          verified: true,
          subscribable: true,
          subscriptionPitch: 'Behind-the-scenes and early drops',
          subscriptionTiersJson: SubscriptionTier.encode(const [
            SubscriptionTier(
                name: 'Supporter', cents: 299, perks: 'Subscriber-only posts'),
            SubscriptionTier(
                name: 'Darkroom',
                cents: 999,
                perks: 'Everything above, plus monthly prints'),
          ]),
        ),
        messages: [
          Message(
            id: 'demo_creator_m1',
            text: 'New set goes up for subscribers tonight 🌘',
            time: DateTime.now().subtract(const Duration(hours: 2)),
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

    // ---- A second server, so Servers is a list ---------------------------
    Community? second;
    for (final c in store.communities) {
      if (c.name == _serverName2) {
        second = c;
        break;
      }
    }
    if (second == null) {
      second = store.createCommunity(
        _serverName2,
        icon: '🏃',
        color: '#2E7D5B',
        description: 'Routes, race reports, and Sunday long runs',
      );
      store.addChannel(second.id, 'routes');
      store.addChannel(second.id, 'race-day', type: ChannelType.announcement);
      store.addChannel(second.id, 'gear-talk', type: ChannelType.forum);
    }
    for (final p in [
      FeedPost(
        id: 'demo_q1',
        communityId: second.id,
        authorName: 'Nadia Okoro',
        authorUsername: 'nadiao',
        time: ago(const Duration(minutes: 50)),
        text: 'Ridge loop was clear this morning — one washout at the '
            'second gate, easy to step round.',
        likes: 11,
        replies: 2,
      ),
      FeedPost(
        id: 'demo_q2',
        communityId: second.id,
        authorName: 'Tom Ashby',
        authorUsername: 'tomashby',
        time: ago(const Duration(hours: 6)),
        text: 'Sunday long run: 7am at the trailhead, 18k, nobody dropped.',
        likes: 17,
        replies: 4,
      ),
      FeedPost(
        id: 'demo_q3',
        communityId: second.id,
        authorName: 'Priya Raman',
        authorUsername: 'priyar',
        authorVerified: true,
        time: ago(const Duration(days: 1, hours: 3)),
        text: 'Race report: finished 4th, and the shoes held up better '
            'than my pacing did.',
        likes: 33,
        replies: 8,
      ),
    ]) {
      feed.addRemote(p);
    }

    // ---- Marketplace: enough to fill a grid -------------------------------
    for (final p in [
      FeedPost(
        id: 'demo_l3',
        communityId: cid,
        authorName: 'Grace Lin',
        authorUsername: 'gracel',
        time: ago(const Duration(hours: 20)),
        text: 'Drafting table, solid oak. Collection only, second floor.',
        priceCents: 18000,
        listingCategory: 'Furniture',
        listingCondition: 'Used',
      ),
      FeedPost(
        id: 'demo_l4',
        communityId: cid,
        authorName: 'Nadia Okoro',
        authorUsername: 'nadiao',
        time: ago(const Duration(days: 1, hours: 4)),
        text: 'Trail shoes, one season on them. Size 9.',
        priceCents: 4500,
        listingCategory: 'Sports',
        listingCondition: 'Good',
      ),
      FeedPost(
        id: 'demo_l5',
        communityId: cid,
        authorName: 'Erin Walsh',
        authorUsername: 'erinw',
        time: ago(const Duration(days: 2, hours: 6)),
        text: 'Box of letterpress type. Mixed faces, mostly 12pt.',
        priceCents: 9000,
        listingCategory: 'Hobbies',
        listingCondition: 'Used',
      ),
      FeedPost(
        id: 'demo_l6',
        communityId: cid,
        authorName: 'Tom Ashby',
        authorUsername: 'tomashby',
        time: ago(const Duration(days: 3)),
        text: 'Free: two crates of plant pots. Gone when they are gone.',
        priceCents: 0,
        listingCategory: 'Garden',
        listingCondition: 'Used',
      ),
    ]) {
      feed.addRemote(p);
    }

    // ---- Notifications ----------------------------------------------------
    // Through the store's own public path, the same one a real mention takes.
    feed.noteChannelMention(
      messageId: _noteIds[0],
      communityId: cid,
      channelId: 'general',
      channelName: 'general',
      actorName: 'Alice Bennett',
      preview: 'can you take the Friday crit? I am travelling',
      time: ago(const Duration(minutes: 12)),
    );
    feed.noteChannelMention(
      messageId: _noteIds[1],
      communityId: second.id,
      channelId: 'routes',
      channelName: 'routes',
      actorName: 'Nadia Okoro',
      preview: 'you were right about the washout',
      time: ago(const Duration(hours: 3)),
    );
    feed.noteChannelMention(
      messageId: _noteIds[2],
      communityId: cid,
      channelId: 'general',
      channelName: 'general',
      actorName: 'Grace Lin',
      preview: 'posted the ampersand photos, have a look',
      time: ago(const Duration(hours: 9)),
    );

    // ---- Notes, bookmarks, folders ---------------------------------------
    // All device-local surfaces that a fresh install leaves blank. Fired and
    // not awaited: populate() is called from a button, and a screenshot build
    // has nothing racing it.
    () async {
      for (final body in _noteBodies) {
        if (!NotesStore.instance.notes.any((n) => n.body == body)) {
          await NotesStore.instance.save(body: body);
        }
      }
      final marks = BookmarkStore.instance;
      await marks.createFolder(_bookmarkFolder);
      for (final id in const ['demo_p3', 'demo_q3']) {
        if (!marks.contains(id)) await marks.toggle(id);
        await marks.setInFolder(_bookmarkFolder, id, true);
      }
      final folders = ChatFolders.instance;
      await folders.create(_chatFolder);
      for (final chat in MockData.chats().take(2)) {
        await folders.setInFolder(_chatFolder, chat.id, true);
      }
    }();
  }

  /// Removes exactly what [populate] added — the mock chats also clear
  /// themselves on the next launch (the store strips `c_` ids on load),
  /// but nobody should have to know that to get their device back.
  static void clear() {
    for (final chat in MockData.chats()) {
      ChatStore.instance.deleteChat(chat.id);
    }
    ChatStore.instance.deleteChat('demo_biz');
    ChatStore.instance.deleteChat('demo_creator');
    for (final call in MockData.calls()) {
      CallLog.instance.remove(call.id);
    }
    for (final id in _postIds) {
      FeedStore.instance.deletePost(id);
    }
    for (final id in _noteIds) {
      FeedStore.instance.dismissNotification(id);
    }
    final store = CommunityStore.instance;
    for (final name in const [_serverName, _serverName2]) {
      for (final c in store.communities.where((c) => c.name == name)) {
        store.deleteCommunity(c.id);
        break;
      }
    }
    () async {
      for (final note in NotesStore.instance.notes
          .where((n) => _noteBodies.contains(n.body))
          .toList()) {
        await NotesStore.instance.delete(note.id);
      }
      final marks = BookmarkStore.instance;
      for (final id in const ['demo_p3', 'demo_q3']) {
        if (marks.contains(id)) await marks.toggle(id);
      }
      await marks.deleteFolder(_bookmarkFolder);
      await ChatFolders.instance.delete(_chatFolder);
    }();
  }
}
