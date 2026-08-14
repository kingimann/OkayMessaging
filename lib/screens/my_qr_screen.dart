import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../util/account_code.dart';
import '../util/backup_export.dart';
import '../theme/app_theme.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app_state.dart';
import '../models/qr_style.dart';
import '../models/user.dart';
import '../payments/nfc_pay.dart';
import '../state/qr_style_store.dart';
import '../widgets/user_avatar.dart';

/// Shows a scannable QR code for the signed-in user, so someone can add them
/// on OkayMessenger by scanning instead of typing a number — and lets them
/// choose how it looks, the way Telegram does.
class MyQrScreen extends StatefulWidget {
  const MyQrScreen({super.key});

  /// The payload encoded in the QR: an app URI carrying the handle, number and
  /// name so a scanner can start a chat.
  ///
  /// **Nothing on this screen changes it.** The colours, the shape and the
  /// photo in the middle are all paint; the code says exactly what it said
  /// before anybody customized anything.
  static String payloadFor(AppUser user) {
    final params = <String, String>{
      if (user.username.isNotEmpty) 'u': user.username,
      if (user.phone.isNotEmpty) 'p': user.phone,
      'n': user.name,
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'okaymsg://add?$query';
  }

  @override
  State<MyQrScreen> createState() => _MyQrScreenState();
}

class _MyQrScreenState extends State<MyQrScreen> {
  /// Wraps only the card, so the shared picture is the card — not the app bar,
  /// the hint sentence or the account code below it.
  final _cardKey = GlobalKey();

  /// Renders the card to a PNG and hands it to the share sheet.
  ///
  /// A picture, not the link: the point of a QR is that it can be sent to
  /// somebody who then shows it to a third person's camera, printed, or put
  /// in a bio — none of which a URL does.
  Future<void> _shareCard() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final boundary = _cardKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      // 3x so the code survives being scaled up by whatever it lands in.
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final result = await shareImageBytes(
          'okay-qr.png', Uint8List.view(data.buffer),
          subject: 'My OkayMessenger code');
      if (result == null) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Couldn\'t share the code.')));
      }
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Couldn\'t share the code.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My QR code'),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share),
            onPressed: _shareCard,
          ),
        ],
      ),
      body: ValueListenableBuilder<AppUser>(
        valueListenable: AppState.profile,
        builder: (context, me, _) => ListenableBuilder(
          listenable: QrStyleStore.instance,
          builder: (context, _) {
            final store = QrStyleStore.instance;
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RepaintBoundary(
                      key: _cardKey,
                      child: _QrCard(
                        user: me,
                        style: store.style,
                        shape: store.shape,
                        showAvatar: store.showAvatar,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _StylePicker(store: store),
                    const SizedBox(height: 14),
                    Text(
                      'Scan this code with the iPhone camera — it opens '
                      'OkayMessenger and starts a chat with ${me.name}.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppColors.subtle(context), height: 1.4),
                    ),
                    // Write the same add-me link onto a blank NFC sticker, so a
                    // tap adds you — a physical "tap to add me" card. Only
                    // offered when the device can do NFC; an iPhone can write a
                    // tag but can't broadcast one, which is why this is a
                    // sticker, not a phone held to a phone (the QR above is the
                    // phone-to-phone way).
                    FutureBuilder<bool>(
                      future: NfcPay.instance.available(),
                      builder: (context, snap) {
                        if (snap.data != true) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              final ok = await NfcPay.instance.shareReceiveTag(
                                  MyQrScreen.payloadFor(me));
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(SnackBar(
                                      content: Text(ok
                                          ? 'Your contact tag is ready.'
                                          : 'Couldn\'t write the tag.')));
                            },
                            icon: const Icon(Icons.contactless_outlined),
                            label: const Text('Write a contact tag'),
                          ),
                        );
                      },
                    ),
                    // An account with no number behind it has nothing anybody
                    // can look up, so the code has to be somewhere it can be
                    // read off this screen and typed into another phone. A QR
                    // is no use at all when the other phone is the one you are
                    // holding.
                    if (AccountCode.isCode(me.phone)) ...[
                      const SizedBox(height: 20),
                      Text('YOUR CODE',
                          style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: AppColors.subtle(context))),
                      const SizedBox(height: 6),
                      SelectableText(
                        AccountCode.pretty(me.phone),
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        icon: const Icon(Icons.copy, size: 17),
                        label: const Text('Copy code'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: me.phone));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Code copied')),
                          );
                        },
                      ),
                      Text(
                        'You have no phone number on this account, so this is '
                        'how people reach you. Anyone with it can start a chat.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: AppColors.subtle(context)),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The card itself — gradient, name, code. Its own widget because it is what
/// the [RepaintBoundary] captures, so what somebody shares is exactly what
/// they were looking at.
class _QrCard extends StatelessWidget {
  const _QrCard({
    required this.user,
    required this.style,
    required this.shape,
    required this.showAvatar,
  });

  final AppUser user;
  final QrStyle style;
  final QrModuleShape shape;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) {
    final ink = style.wantsLightInk ? Colors.white : const Color(0xFF0F1419);
    final round = shape == QrModuleShape.round;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [style.start, style.end],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            user.name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700, color: ink),
          ),
          if (user.handle.isNotEmpty)
            Text(user.handle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13.5, color: ink.withValues(alpha: 0.75))),
          const SizedBox(height: 16),
          Stack(
            alignment: Alignment.center,
            children: [
              QrImageView(
                data: MyQrScreen.payloadFor(user),
                version: QrVersions.auto,
                size: 240,
                backgroundColor: Colors.transparent,
                // The highest level, always — not only when the photo is
                // covering the middle. A code that survives a thumbprint,
                // a crease and a bad camera is worth the extra modules,
                // and it is the same correction that makes the centre
                // cut-out safe rather than a gamble.
                errorCorrectionLevel: QrErrorCorrectLevel.H,
                eyeStyle: QrEyeStyle(
                  eyeShape: round ? QrEyeShape.circle : QrEyeShape.square,
                  color: style.module,
                ),
                dataModuleStyle: QrDataModuleStyle(
                  dataModuleShape: round
                      ? QrDataModuleShape.circle
                      : QrDataModuleShape.square,
                  color: style.module,
                ),
              ),
              if (showAvatar)
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    // The gradient's own colour, so the cut-out reads as a
                    // hole in the code rather than a sticker on top of it.
                    color: style.field,
                    shape: BoxShape.circle,
                  ),
                  child: UserAvatar(user: user, radius: 26),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The row of looks, plus the two switches. Below the card and never over it:
/// the card is the thing being shared, and a control drawn on it would end up
/// in the picture.
class _StylePicker extends StatelessWidget {
  const _StylePicker({required this.store});

  final QrStyleStore store;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 54,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: qrStyles.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final s = qrStyles[i];
              final selected = s.id == store.style.id;
              return Semantics(
                selected: selected,
                button: true,
                label: s.name,
                child: GestureDetector(
                  onTap: () => store.setStyle(s),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [s.start, s.end],
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? AppColors.accentOn(context)
                            : AppColors.subtle(context)
                                .withValues(alpha: 0.35),
                        width: selected ? 2.5 : 1,
                      ),
                    ),
                    // A dot of the module colour, so a swatch says what the
                    // code will be drawn IN as well as what it sits on.
                    child: Center(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                            color: s.module, shape: BoxShape.circle),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: SegmentedButton<QrModuleShape>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                    visualDensity: VisualDensity.compact),
                segments: [
                  for (final s in QrModuleShape.values)
                    ButtonSegment(value: s, label: Text(s.label)),
                ],
                selected: {store.shape},
                onSelectionChanged: (v) => store.setShape(v.first),
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: store.showAvatar,
          onChanged: store.setShowAvatar,
          title: const Text('Show my photo'),
          subtitle: Text(
            'In the middle of the code. It still scans — the code carries '
            'enough spare to lose the middle.',
            style: TextStyle(fontSize: 12, color: AppColors.subtle(context)),
          ),
        ),
      ],
    );
  }
}
