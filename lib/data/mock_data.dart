import '../models/call.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../models/status.dart';
import '../models/user.dart';

/// In-memory sample data that powers the UI-only clone.
class MockData {
  MockData._();

  static const AppUser me = AppUser(
    id: 'me',
    name: 'You',
    avatarColor: '#25D366',
    about: 'Available',
    phone: '+1 555 0100',
  );

  static const AppUser _alice = AppUser(
    id: 'u_alice',
    name: 'Alice Bennett',
    avatarColor: '#E57373',
    about: 'At the gym 💪',
    phone: '+1 555 0111',
    isOnline: true,
  );

  static const AppUser _bob = AppUser(
    id: 'u_bob',
    name: 'Bob Carter',
    avatarColor: '#64B5F6',
    about: 'Busy',
    phone: '+1 555 0122',
  );

  static const AppUser _carol = AppUser(
    id: 'u_carol',
    name: 'Carol Diaz',
    avatarColor: '#BA68C8',
    about: 'Sleeping 😴',
    phone: '+1 555 0133',
  );

  static const AppUser _dev = AppUser(
    id: 'u_dev',
    name: 'Team Standup',
    avatarColor: '#4DB6AC',
    about: 'Group • 6 members',
    phone: '',
  );

  static const AppUser _erin = AppUser(
    id: 'u_erin',
    name: 'Erin Foster',
    avatarColor: '#FFB74D',
    about: 'Travelling ✈️',
    phone: '+1 555 0144',
    isOnline: true,
  );

  static const AppUser _frank = AppUser(
    id: 'u_frank',
    name: 'Frank Green',
    avatarColor: '#A1887F',
    about: 'Can\'t talk, WhatsApp only',
    phone: '+1 555 0155',
  );

  static DateTime _ago(Duration d) => DateTime.now().subtract(d);

  /// Individual people available to start a new conversation with
  /// (groups such as "Team Standup" are excluded).
  static List<AppUser> contacts() => [_alice, _bob, _carol, _erin, _frank]
    ..sort((a, b) => a.name.compareTo(b.name));

  static List<Chat> chats() {
    return [
      Chat(
        id: 'c_alice',
        contact: _alice,
        unreadCount: 2,
        isPinned: true,
        messages: [
          Message(
            id: 'm1',
            text: 'Hey! Are we still on for lunch tomorrow?',
            time: _ago(const Duration(minutes: 42)),
            isMe: false,
          ),
          Message(
            id: 'm2',
            text: 'Absolutely, 12:30 works for me 🙂',
            time: _ago(const Duration(minutes: 40)),
            isMe: true,
            status: MessageStatus.read,
          ),
          Message(
            id: 'm3',
            text: 'Perfect. I\'ll book a table.',
            time: _ago(const Duration(minutes: 8)),
            isMe: false,
          ),
          Message(
            id: 'm4',
            text: 'Can\'t wait 😄',
            time: _ago(const Duration(minutes: 6)),
            isMe: false,
          ),
        ],
      ),
      Chat(
        id: 'c_dev',
        contact: _dev,
        unreadCount: 5,
        messages: [
          Message(
            id: 'm1',
            text: 'Standup in 10 minutes everyone',
            time: _ago(const Duration(hours: 2)),
            isMe: false,
          ),
          Message(
            id: 'm2',
            text: 'On my way',
            time: _ago(const Duration(hours: 1, minutes: 58)),
            isMe: true,
            status: MessageStatus.delivered,
          ),
          Message(
            id: 'm3',
            text: 'Ship date pushed to Friday 🚀',
            time: _ago(const Duration(hours: 1, minutes: 30)),
            isMe: false,
          ),
        ],
      ),
      Chat(
        id: 'c_bob',
        contact: _bob,
        messages: [
          Message(
            id: 'm1',
            text: 'Did you see the game last night?',
            time: _ago(const Duration(hours: 5)),
            isMe: false,
          ),
          Message(
            id: 'm2',
            text: 'Yes! What a finish 🔥',
            time: _ago(const Duration(hours: 4, minutes: 50)),
            isMe: true,
            status: MessageStatus.read,
          ),
        ],
      ),
      Chat(
        id: 'c_erin',
        contact: _erin,
        unreadCount: 1,
        messages: [
          Message(
            id: 'm1',
            text: 'Landed safely! ✈️',
            time: _ago(const Duration(days: 1, hours: 3)),
            isMe: false,
          ),
          Message(
            id: 'm2',
            text: 'Postcard coming your way 📮',
            time: _ago(const Duration(hours: 20)),
            isMe: false,
          ),
        ],
      ),
      Chat(
        id: 'c_carol',
        contact: _carol,
        messages: [
          Message(
            id: 'm1',
            text: 'Thanks for the help today!',
            time: _ago(const Duration(days: 1, hours: 6)),
            isMe: false,
          ),
          Message(
            id: 'm2',
            text: 'Anytime 🙌',
            time: _ago(const Duration(days: 1, hours: 5)),
            isMe: true,
            status: MessageStatus.read,
          ),
        ],
      ),
      Chat(
        id: 'c_frank',
        contact: _frank,
        messages: [
          Message(
            id: 'm1',
            text: 'Let\'s catch up next week',
            time: _ago(const Duration(days: 3)),
            isMe: true,
            status: MessageStatus.read,
          ),
        ],
      ),
    ];
  }

  static List<StatusUpdate> statuses() {
    return [
      StatusUpdate(
        id: 's_alice',
        user: _alice,
        time: _ago(const Duration(minutes: 25)),
        frameCount: 3,
      ),
      StatusUpdate(
        id: 's_erin',
        user: _erin,
        time: _ago(const Duration(hours: 1, minutes: 10)),
        frameCount: 1,
      ),
      StatusUpdate(
        id: 's_bob',
        user: _bob,
        time: _ago(const Duration(hours: 4)),
        viewed: true,
        frameCount: 2,
      ),
      StatusUpdate(
        id: 's_carol',
        user: _carol,
        time: _ago(const Duration(hours: 8)),
        viewed: true,
        frameCount: 1,
      ),
    ];
  }

  static List<CallRecord> calls() {
    return [
      CallRecord(
        id: 'call1',
        user: _alice,
        time: _ago(const Duration(minutes: 30)),
        type: CallType.video,
        direction: CallDirection.outgoing,
      ),
      CallRecord(
        id: 'call2',
        user: _bob,
        time: _ago(const Duration(hours: 3)),
        type: CallType.voice,
        direction: CallDirection.missed,
      ),
      CallRecord(
        id: 'call3',
        user: _erin,
        time: _ago(const Duration(hours: 6)),
        type: CallType.voice,
        direction: CallDirection.incoming,
      ),
      CallRecord(
        id: 'call4',
        user: _carol,
        time: _ago(const Duration(days: 1)),
        type: CallType.video,
        direction: CallDirection.incoming,
      ),
      CallRecord(
        id: 'call5',
        user: _frank,
        time: _ago(const Duration(days: 2)),
        type: CallType.voice,
        direction: CallDirection.missed,
      ),
    ];
  }
}
