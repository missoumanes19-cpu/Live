import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../state/app_settings.dart';

class ParentalControl extends ChangeNotifier {
  final _box = Hive.box('settings');

  String _hash(String pin) => sha256.convert(utf8.encode('iptv_salt_$pin')).toString();
  bool get hasPin => _box.get('pin') != null;
  bool verify(String pin) => _box.get('pin') == _hash(pin);
  Set<String> get locked => Set<String>.from(_box.get('locked', defaultValue: <String>[]));
  bool isLocked(String category) => locked.contains(category);

  bool setPin(String pin, {String? oldPin}) {
    if (hasPin && (oldPin == null || !verify(oldPin))) return false;
    _box.put('pin', _hash(pin)); notifyListeners(); return true;
  }

  void toggleCategory(String category) {
    final s = locked; s.contains(category) ? s.remove(category) : s.add(category);
    _box.put('locked', s.toList()); notifyListeners();
  }

  int _fails = 0;
  DateTime? _lockUntil;

  /// استدعها قبل فتح أي تصنيف محجوب. بعد 3 محاولات خاطئة يُقفل الإدخال دقيقة (تتضاعف)
  Future<bool> guard(BuildContext ctx, String category) async {
    if (!hasPin || !isLocked(category)) return true;
    final until = _lockUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      final left = until.difference(DateTime.now()).inSeconds + 1;
      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('${t('محاولات كثيرة، انتظر')} $left s')));
      return false;
    }
    final c = TextEditingController();
    final ok = await showDialog<bool>(context: ctx, builder: (d) => AlertDialog(
      title: Text(t('أدخل رمز PIN')),
      content: TextField(controller: c, obscureText: true, autofocus: true,
          keyboardType: TextInputType.number, maxLength: 4),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t('إلغاء'))),
        TextButton(onPressed: () => Navigator.pop(d, verify(c.text)), child: Text(t('موافق'))),
      ],
    ));
    if (ok == true) { _fails = 0; _lockUntil = null; return true; }
    if (ok == false && c.text.isNotEmpty) {
      _fails++;
      if (_fails >= 3) {
        final secs = 60 * (1 << ((_fails - 3).clamp(0, 4)));
        _lockUntil = DateTime.now().add(Duration(seconds: secs));
      }
    }
    return false;
  }
}
