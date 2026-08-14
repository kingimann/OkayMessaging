import 'package:flutter/material.dart';

import 'sanction_notice.dart' show showReportSheet;

/// The one way any surface offers "report this".
///
/// Reporting used to exist on four surfaces and not on the rest: the public
/// newsfeed, the server feed, a marketplace listing and a contact card each
/// grew their own sheet, while the PUBLIC FORUM — posts and comments both,
/// world-readable content anybody can find — the in-server board and a
/// server's channel messages offered no way to report anything at all. A
/// moderation queue only ever sees what somebody can reach a button to send
/// it, so the missing buttons were the missing reports.
///
/// This is deliberately thin. It does not re-implement the sheet
/// ([showReportSheet] already collects a reason and files it); it just gives
/// every surface the same MENU ROW and the same context format, so a
/// moderator reading the console sees one vocabulary instead of six.
///
/// **The context string is a locator, never content.** `forum_comment:42`
/// says which comment on which surface; it does not carry what was written.
/// For the public surfaces a moderator can go and read the thing (it is
/// public); for a server's own content they cannot, and must not — it is
/// end-to-end encrypted, and a report that smuggled the plaintext out would
/// break the promise the encryption exists to keep. That is the same rule
/// the server-feed report already follows: "who and where, never what".
enum ReportTarget {
  forumPost('forum_post', 'post'),
  forumComment('forum_comment', 'comment'),
  serverForumThread('server_forum_post', 'post'),
  channelMessage('channel_message', 'message');

  const ReportTarget(this.prefix, this.noun);

  /// What the console sees, ahead of the id.
  final String prefix;

  /// What the menu row calls the thing being reported.
  final String noun;
}

/// A menu row that reports [id] by [authorHandle]. Drop it into any sheet.
///
/// [extra] is appended to the context for surfaces where the id alone would
/// not let a moderator find it — a channel message needs its server and
/// channel, a bare message id names nothing.
ListTile reportMenuRow(
  BuildContext context, {
  required ReportTarget target,
  required String id,
  required String authorHandle,
  String extra = '',
  VoidCallback? onDone,
}) {
  return ListTile(
    leading: const Icon(Icons.flag_outlined),
    title: Text('Report ${target.noun}'),
    subtitle: const Text('Sent to the app\'s moderators'),
    onTap: () {
      // Close the host sheet FIRST: two stacked modal sheets leaves the
      // report sitting on top of a menu nobody can see behind it, and
      // dismissing the report then reveals a menu the person thought they
      // had already left.
      Navigator.of(context).pop();
      onDone?.call();
      showReportSheet(
        context,
        context_: [
          '${target.prefix}:$id',
          if (extra.isNotEmpty) extra,
        ].join(' '),
        targetHandle: authorHandle,
      );
    },
  );
}

/// Opens a sheet whose only row is [reportMenuRow] — for a surface with no
/// existing overflow menu to add it to.
Future<void> showReportOnlySheet(
  BuildContext context, {
  required ReportTarget target,
  required String id,
  required String authorHandle,
  String extra = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          reportMenuRow(
            sheetContext,
            target: target,
            id: id,
            authorHandle: authorHandle,
            extra: extra,
          ),
        ],
      ),
    ),
  );
}
