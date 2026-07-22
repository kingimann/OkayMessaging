/// Represents a person in the app (a contact or the current user).
class AppUser {
  final String id;
  final String name;
  final String avatarColor; // hex string used to build a placeholder avatar
  final String about;
  final String phone;

  /// A public handle (without the leading '@'), e.g. "ada".
  final String username;
  final bool isOnline;

  /// True for group conversations rather than a single person.
  final bool isGroup;

  const AppUser({
    required this.id,
    required this.name,
    required this.avatarColor,
    this.about = 'Hey there! I am using Okay Messaging.',
    this.phone = '',
    this.username = '',
    this.isOnline = false,
    this.isGroup = false,
  });

  /// The handle with a leading '@', or empty when none is set.
  String get handle => username.isEmpty ? '' : '@$username';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatarColor': avatarColor,
        'about': about,
        'phone': phone,
        'username': username,
        'isOnline': isOnline,
        'isGroup': isGroup,
      };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        avatarColor: json['avatarColor'] as String,
        about: json['about'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        username: json['username'] as String? ?? '',
        isOnline: json['isOnline'] as bool? ?? false,
        isGroup: json['isGroup'] as bool? ?? false,
      );

  /// Initials used for the placeholder avatar (e.g. "John Doe" -> "JD").
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}
