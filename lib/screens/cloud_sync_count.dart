/// "3 chats" / "1 chat" — a pluralised count for the backup summary. Pure.
String backupCount(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
