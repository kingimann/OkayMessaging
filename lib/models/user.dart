/// Represents a person in the app (a contact or the current user).
class AppUser {
  final String id;
  final String name;
  final String avatarColor; // hex string used to build a placeholder avatar
  final String about;
  final String phone;
  final bool isOnline;

  const AppUser({
    required this.id,
    required this.name,
    required this.avatarColor,
    this.about = 'Hey there! I am using Okay Messaging.',
    this.phone = '',
    this.isOnline = false,
  });

  /// Initials used for the placeholder avatar (e.g. "John Doe" -> "JD").
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}
