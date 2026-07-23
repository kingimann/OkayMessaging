import '../models/chat.dart';
import '../models/message.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// A short bracketed placeholder for a non-text message.
String _body(Message m) {
  if (m.isDeleted) return '[deleted]';
  if (m.viewOnce) return '[view once photo]';
  if (m.isImage) return '[photo]';
  if (m.isVoice) return '[voice message]';
  if (m.isLocation) return '[location]';
  if (m.isContact) return '[contact: ${m.contactName}]';
  if (m.isPayment) return '[payment]';
  if (m.isPoll) return '[poll: ${m.pollQuestion}]';
  return m.text;
}

/// Builds a plain-text transcript of [chat], grouped by date, as WhatsApp-style
/// "[HH:MM] Name: message" lines. Pure and testable (no locale / "now"
/// dependency).
String buildChatTranscript(Chat chat, String myName) {
  final b = StringBuffer()
    ..writeln('Chat with ${chat.contact.name}')
    ..writeln('Exported from Okay Messaging')
    ..writeln();
  String? lastDate;
  for (final m in chat.messages) {
    final d = _date(m.time);
    if (d != lastDate) {
      if (lastDate != null) b.writeln();
      b.writeln('— $d —');
      lastDate = d;
    }
    final who = m.isMe ? myName : chat.contact.name;
    b.writeln('[${_time(m.time)}] $who: ${_body(m)}');
  }
  return b.toString();
}

/// A safe file name for the exported transcript, e.g.
/// "okay-chat-alice-bennett.txt".
String transcriptFileName(String contactName) {
  final slug = contactName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return 'okay-chat-${slug.isEmpty ? 'export' : slug}.txt';
}
