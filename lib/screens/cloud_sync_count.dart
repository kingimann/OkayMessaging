/// "3 chats" / "1 chat" — a pluralised count for the backup summary. Pass
/// [plural] for nouns that don't just take an 's' ("communities"). Pure.
String backupCount(int n, String noun, {String? plural}) =>
    n == 1 ? '$n $noun' : '$n ${plural ?? '${noun}s'}';
