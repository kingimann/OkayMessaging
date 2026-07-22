import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../relay/relay_service.dart';
import '../util/file_saver.dart';

/// One in-progress peer-to-peer file transfer.
@immutable
class FileTransferState {
  final String transferId;
  final String peerPhone;
  final String peerName;
  final String fileName;
  final int total;
  final int transferred;
  final bool incoming;

  /// 'offering' | 'transferring' | 'done' | 'failed' | 'declined'
  final String status;

  const FileTransferState({
    required this.transferId,
    required this.peerPhone,
    required this.peerName,
    required this.fileName,
    required this.total,
    required this.transferred,
    required this.incoming,
    required this.status,
  });

  double get progress => total == 0 ? 0 : (transferred / total).clamp(0, 1);

  FileTransferState copyWith({int? transferred, String? status}) =>
      FileTransferState(
        transferId: transferId,
        peerPhone: peerPhone,
        peerName: peerName,
        fileName: fileName,
        total: total,
        transferred: transferred ?? this.transferred,
        incoming: incoming,
        status: status ?? this.status,
      );
}

/// Sends files **directly between devices** over a WebRTC data channel — the
/// bytes never touch any server (only the tiny SDP/ICE handshake rides the
/// relay). Both peers must be online at the same time, since nothing is stored.
///
/// Only active where WebRTC is available (web + native); a safe no-op on the
/// Dart VM used by tests. All the pure chunking logic in [chunk]/[reassemble]
/// is unit-tested.
class FileTransfer {
  FileTransfer._();
  static final FileTransfer instance = FileTransfer._();

  static const int chunkSize = 16 * 1024; // 16 KB
  static const String _eof = '__OKAY_EOF__';

  final ValueNotifier<FileTransferState?> current =
      ValueNotifier<FileTransferState?>(null);

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;

  // Receiver side.
  final List<int> _incomingBytes = [];
  String? _pendingOfferSdp;

  bool get isSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  static Map<String, dynamic> get _config => {
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ],
      };

  // --- Pure, unit-tested chunking protocol -------------------------------

  /// Splits [bytes] into [chunkSize]-sized pieces.
  static List<Uint8List> chunk(Uint8List bytes) {
    final out = <Uint8List>[];
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize < bytes.length) ? i + chunkSize : bytes.length;
      out.add(Uint8List.sublistView(bytes, i, end));
    }
    return out;
  }

  /// Reassembles chunks back into one buffer.
  static Uint8List reassemble(List<Uint8List> chunks) {
    final total = chunks.fold<int>(0, (n, c) => n + c.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final c in chunks) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }

  String _newId(String peerPhone) =>
      'ft_${RelayService.digits(peerPhone)}_${DateTime.now().millisecondsSinceEpoch}';

  // --- Sender ------------------------------------------------------------

  Future<void> sendFile(
      String peerPhone, String peerName, String fileName, Uint8List bytes) async {
    if (!isSupported) return;
    await _reset();
    final id = _newId(peerPhone);
    RelayService.instance.currentFileId = id;
    current.value = FileTransferState(
      transferId: id,
      peerPhone: peerPhone,
      peerName: peerName,
      fileName: fileName,
      total: bytes.length,
      transferred: 0,
      incoming: false,
      status: 'offering',
    );
    try {
      final pc = await createPeerConnection(_config);
      _pc = pc;
      pc.onIceCandidate = (c) {
        if (c.candidate != null) {
          RelayService.instance.sendFileSignal(peerPhone,
              kind: 'ice', ice: {
                'candidate': c.candidate,
                'sdpMid': c.sdpMid,
                'sdpMLineIndex': c.sdpMLineIndex,
              });
        }
      };
      final dc = await pc.createDataChannel(
          'file', RTCDataChannelInit()..ordered = true);
      _dc = dc;
      dc.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _sendBytes(dc, fileName, bytes);
        }
      };
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      RelayService.instance.sendFileSignal(peerPhone,
          kind: 'offer',
          sdp: offer.sdp,
          fileName: fileName,
          size: bytes.length);
    } catch (_) {
      _fail();
    }
  }

  Future<void> _sendBytes(
      RTCDataChannel dc, String fileName, Uint8List bytes) async {
    try {
      dc.send(RTCDataChannelMessage(
          jsonEncode({'name': fileName, 'size': bytes.length})));
      final chunks = chunk(bytes);
      var sent = 0;
      for (var i = 0; i < chunks.length; i++) {
        dc.send(RTCDataChannelMessage.fromBinary(chunks[i]));
        sent += chunks[i].length;
        final c = current.value;
        if (c != null) {
          current.value = c.copyWith(transferred: sent, status: 'transferring');
        }
        // Yield periodically so the channel buffer can drain.
        if (i % 16 == 0) await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      dc.send(RTCDataChannelMessage(_eof));
      final c = current.value;
      if (c != null) current.value = c.copyWith(status: 'done');
    } catch (_) {
      _fail();
    }
  }

  // --- Receiver ----------------------------------------------------------

  void onRemoteOffer(String peerPhone, String peerName, String transferId,
      String fileName, int size, String sdp) {
    if (current.value?.status == 'transferring') {
      // Busy — decline.
      RelayService.instance
          .sendFileSignal(peerPhone, kind: 'decline', transferId: transferId);
      return;
    }
    _pendingOfferSdp = sdp;
    RelayService.instance.currentFileId = transferId;
    current.value = FileTransferState(
      transferId: transferId,
      peerPhone: peerPhone,
      peerName: peerName,
      fileName: fileName,
      total: size,
      transferred: 0,
      incoming: true,
      status: 'offering',
    );
  }

  Future<void> accept() async {
    final c = current.value;
    final offer = _pendingOfferSdp;
    if (c == null || !c.incoming || offer == null || !isSupported) return;
    current.value = c.copyWith(status: 'transferring');
    try {
      final pc = await createPeerConnection(_config);
      _pc = pc;
      pc.onIceCandidate = (cand) {
        if (cand.candidate != null) {
          RelayService.instance.sendFileSignal(c.peerPhone, kind: 'ice', ice: {
            'candidate': cand.candidate,
            'sdpMid': cand.sdpMid,
            'sdpMLineIndex': cand.sdpMLineIndex,
          });
        }
      };
      pc.onDataChannel = (dc) {
        _dc = dc;
        dc.onMessage = (msg) => _onData(dc, msg);
      };
      await pc.setRemoteDescription(RTCSessionDescription(offer, 'offer'));
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      RelayService.instance
          .sendFileSignal(c.peerPhone, kind: 'answer', sdp: answer.sdp);
    } catch (_) {
      _fail();
    }
  }

  Future<void> _onData(RTCDataChannel dc, RTCDataChannelMessage msg) async {
    try {
      if (msg.isBinary) {
        _incomingBytes.addAll(msg.binary);
        final c = current.value;
        if (c != null) {
          current.value = c.copyWith(transferred: _incomingBytes.length);
        }
      } else if (msg.text == _eof) {
        final c = current.value;
        if (c != null) {
          await saveIncomingFile(c.fileName, Uint8List.fromList(_incomingBytes));
          current.value = c.copyWith(status: 'done');
        }
      }
      // The JSON header (first text message) is informational; size comes from
      // the offer, so we ignore it here.
    } catch (_) {
      _fail();
    }
  }

  void decline() {
    final c = current.value;
    if (c != null) {
      RelayService.instance.sendFileSignal(c.peerPhone,
          kind: 'decline', transferId: c.transferId);
    }
    _reset();
  }

  // --- Remote signaling --------------------------------------------------

  Future<void> onRemoteAnswer(String sdp) async {
    if (_pc == null) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    } catch (_) {}
  }

  Future<void> onRemoteIce(Map<String, dynamic> c) async {
    if (_pc == null) return;
    try {
      await _pc!.addCandidate(RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (_) {}
  }

  void onRemoteDecline() {
    final c = current.value;
    if (c != null) current.value = c.copyWith(status: 'declined');
  }

  void clear() => _reset();

  void _fail() {
    final c = current.value;
    if (c != null) current.value = c.copyWith(status: 'failed');
  }

  Future<void> _reset() async {
    try {
      await _dc?.close();
      await _pc?.close();
    } catch (_) {}
    _dc = null;
    _pc = null;
    _pendingOfferSdp = null;
    _incomingBytes.clear();
    current.value = null;
  }

  @visibleForTesting
  void resetForTest() {
    _dc = null;
    _pc = null;
    _pendingOfferSdp = null;
    _incomingBytes.clear();
    current.value = null;
  }
}
