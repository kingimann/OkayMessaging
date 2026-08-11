import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show SHA256Digest;

import 'bip340.dart';

/// A signed Nostr event — the only wire format Nostr Wallet Connect speaks.
///
/// Pure and self-contained: given a private key, a kind, tags and content, it
/// produces the exact JSON a relay accepts. Nothing here touches the network,
/// so the id and signature can be proven in a test on a machine with no relay
/// to talk to.
class NostrEvent {
  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// NIP-01's serialization for the id: a compact JSON ARRAY, not the event
  /// object — `[0, pubkey, created_at, kind, tags, content]`.
  ///
  /// It must have no whitespace and the fields in exactly this order, because
  /// the id is the hash of these bytes and every relay recomputes it. Dart's
  /// `jsonEncode` emits compact JSON with the spec's escaping for the
  /// characters that can appear here, and NWC content is base64 plus `?iv=`,
  /// which contains none of the awkward ones.
  static String serializeForId(
          String pubkey, int createdAt, int kind, List<List<String>> tags, String content) =>
      jsonEncode([0, pubkey, createdAt, kind, tags, content]);

  /// Builds and signs an event. [auxRand] is BIP-340's randomness, exposed so
  /// a test can pin an exact signature; callers pass real bytes.
  static NostrEvent sign({
    required Uint8List privateKey,
    required int kind,
    required List<List<String>> tags,
    required String content,
    required int createdAt,
    required Uint8List auxRand,
  }) {
    final pubkey = _hex(Bip340.publicKey(privateKey));
    final serialized = serializeForId(pubkey, createdAt, kind, tags, content);
    final id = SHA256Digest().process(Uint8List.fromList(utf8.encode(serialized)));
    final sig = Bip340.sign(privateKey, id, auxRand);
    return NostrEvent(
      id: _hex(id),
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
      sig: _hex(sig),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

  /// Parses a relay's event object. Returns null on anything that is not one,
  /// so a malformed frame can never be mistaken for a wallet's reply.
  static NostrEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], pk = raw['pubkey'], kind = raw['kind'];
    if (id is! String || pk is! String || kind is! int) return null;
    return NostrEvent(
      id: id,
      pubkey: pk,
      createdAt: raw['created_at'] is int ? raw['created_at'] as int : 0,
      kind: kind,
      tags: [
        for (final t in (raw['tags'] is List ? raw['tags'] as List : const []))
          if (t is List) [for (final v in t) '$v']
      ],
      content: raw['content'] is String ? raw['content'] as String : '',
      sig: raw['sig'] is String ? raw['sig'] as String : '',
    );
  }

  /// The first value of the first tag named [name], or ''.
  String tag(String name) {
    for (final t in tags) {
      if (t.length >= 2 && t[0] == name) return t[1];
    }
    return '';
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
