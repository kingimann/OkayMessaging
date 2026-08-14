import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/qr_style.dart';

/// Which look the QR card wears, and whether it carries your photo.
///
/// Account-scoped like every other preference that describes a PERSON rather
/// than the phone: the card is your identity card, and the next account to
/// sign in on this handset should get its own, not inherit one. Wired into
/// [AccountWipe]'s reset-and-reload pair for exactly that reason.
class QrStyleStore extends ChangeNotifier {
  QrStyleStore._();
  static final QrStyleStore instance = QrStyleStore._();

  static const _styleKey = 'qr_style_v1';
  static const _shapeKey = 'qr_shape_v1';
  static const _avatarKey = 'qr_avatar_v1';

  SharedPreferences? _prefs;

  QrStyle _style = qrStyles.first;
  QrModuleShape _shape = QrModuleShape.square;
  bool _showAvatar = true;

  QrStyle get style => _style;
  QrModuleShape get shape => _shape;

  /// Whether the profile photo sits in the middle of the code.
  bool get showAvatar => _showAvatar;

  Future<void> load() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    _style = qrStyleById(prefs.getString(_styleKey) ?? '');
    _shape = QrModuleShape.fromId(prefs.getString(_shapeKey) ?? '');
    _showAvatar = prefs.getBool(_avatarKey) ?? true;
    notifyListeners();
  }

  Future<void> setStyle(QrStyle style) async {
    if (style.id == _style.id) return;
    _style = style;
    notifyListeners();
    await (_prefs ??= await SharedPreferences.getInstance())
        .setString(_styleKey, style.id);
  }

  Future<void> setShape(QrModuleShape shape) async {
    if (shape == _shape) return;
    _shape = shape;
    notifyListeners();
    await (_prefs ??= await SharedPreferences.getInstance())
        .setString(_shapeKey, shape.name);
  }

  Future<void> setShowAvatar(bool show) async {
    if (show == _showAvatar) return;
    _showAvatar = show;
    notifyListeners();
    await (_prefs ??= await SharedPreferences.getInstance())
        .setBool(_avatarKey, show);
  }

  @visibleForTesting
  void resetForTest() {
    _style = qrStyles.first;
    _shape = QrModuleShape.square;
    _showAvatar = true;
    _prefs = null;
    notifyListeners();
  }
}
