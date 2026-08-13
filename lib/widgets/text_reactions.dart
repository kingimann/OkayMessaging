/// Short-text reactions, offered beside emoji in the reaction picker.
///
/// A reaction is already stored as plain text on the wire and on disk
/// (`Message.reactions`/`reactionsBy`, `ChatStore.toggleReaction`) — nothing
/// there assumes a single emoji glyph. What was missing was a way to PICK
/// one: the quick-react row and the emoji grid are the only two entry
/// points into `_react`. This is a third, offering a phrase instead of a
/// glyph for the moments a glyph doesn't say enough ("On it", not just 👍)
/// but a whole reply is more than the moment calls for — the same instinct
/// `QuickReplies` serves for full messages, kept separate because a
/// reaction is never sent as one: it rides the reaction funnel, not the
/// composer.
class TextReactions {
  TextReactions._();

  static const List<String> defaults = [
    'On it',
    'LOL',
    'Will reply later',
    'Thanks!',
    'Same',
  ];

  /// The longest a text reaction may be — a floating badge, not a message.
  static const int maxLength = 24;

  /// Trims and rejects anything empty or over [maxLength]. Returns the
  /// text to react with, or null when it was refused.
  static String? clean(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.length > maxLength) return null;
    return text;
  }
}
